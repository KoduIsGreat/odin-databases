// schemagen — generate typed column descriptors (and, in DB mode, row
// structs) for the sqlbuilder typed layer, one descriptor object per table.
//
// Usage:
//   odin run tools/schemagen -- <pkg-dir>                            # struct front-end
//   odin run tools/schemagen -- -db=<path> [-package=<n>] [-structs=singular|none] <pkg-dir>
//   odin run tools/schemagen -- -driver=postgres -db=<dsn> [...] <pkg-dir>
//
// schemagen is built around an internal `Schema` model that decouples the
// *source* of the schema from the *emitted* code. The front-ends populate the
// same `Schema` and share one `emit`:
//
//   - front_end_structs: reads annotated Odin structs (the struct is the
//     source of truth; the row struct already exists, so only descriptors are
//     emitted). A `Maybe(T)` field marks the column nullable and maps the
//     descriptor to `Column(T)`. Driver-agnostic.
//   - front_end_db (SQLite, default): opens a `.db` file and reads its schema
//     via PRAGMA. The database is the source of truth, so row structs AND
//     descriptors are emitted (unless -structs=none).
//   - front_end_db_postgres (`-driver=postgres`, `-db=<dsn>`): introspects a
//     live PostgreSQL server via information_schema. Same emitted output as the
//     SQLite DB front-end.
//   - front_end_db_duckdb (`-driver=duckdb`, `-db=<path>`): introspects a DuckDB
//     database via information_schema. Opt-in (links libduckdb): build with
//     `-define:SCHEMAGEN_DUCKDB=true`. Composite columns (LIST/STRUCT/MAP/...)
//     have no single-field mapping and are skipped with a warning.
//
// Nullability
//
// Nullable columns map to `Maybe(T)` struct fields and set `nullable = true`
// on the descriptor (the descriptor's `Column(T)` always uses the base type
// `T`; the nullability is metadata). The reflective `sql.scan_struct` and
// scangen both scan a NULL into a `Maybe(T)` field as `None`.
//
// DB-mode struct naming (-structs)
//
//   - singular (default): the row struct is the singularized, PascalCased
//     table name (users → User, categories → Category). If that collides with
//     the descriptor name (a singular table like `user`), `_Row` is appended.
//   - none: no row structs are emitted (descriptors only) — define your own,
//     often partial, structs and scan into them.
//
// Generated row structs are tagged `//+sql:scan` so scangen produces concrete
// scanners for them (run scangen after schemagen).
//
// Type mapping (DB mode): int family → i64, REAL → f64, TEXT → string,
// BLOB/none → []byte, DATE/TIME family → time.Time, JSON → string (JSONB →
// []byte), BOOLEAN → bool; NUMERIC/unrecognized affinities default to f64
// (the scan layer coerces an integral i64 into a float field). Mirrors the
// driver so generated types match scan results.
package schemagen

import "core:flags"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import postgres "database:drivers/postgres"
import sqlite "database:drivers/sqlite"
import sql "database:sql"

// DuckDB introspection links libduckdb (a fetched shared lib), so it's opt-in
// at build time to keep the default schemagen / `odb` CLI free of that runtime
// dependency. Enable with `-define:SCHEMAGEN_DUCKDB=true` (and set the libduckdb
// loader path). `duck` is referenced only under `when DUCKDB_INTROSPECT`, so a
// default build neither links nor requires libduckdb.
DUCKDB_INTROSPECT :: #config(SCHEMAGEN_DUCKDB, false)
import duck "database:drivers/duckdb"

// --- Internal schema model (the front-end ⇄ emit seam) ---

Column_Spec :: struct {
	name:      string,
	odin_type: string, // base Odin type: the Column(T) arg, type_id, and (unless nullable) the struct field type
	nullable:  bool,
}

Table_Spec :: struct {
	name:        string, // SQL table name, e.g. "users"
	accessor:    string, // generated descriptor var name, e.g. "Users"
	struct_name: string, // generated row struct name (DB mode), e.g. "User"
	columns:     [dynamic]Column_Spec,
}

Struct_Mode :: enum {
	Singular, // row struct = singularized PascalCase table name (default)
	None, // descriptors only; no row structs
}

// Driver_Kind selects which driver the DB front-end introspects through.
// `-db` carries a file path for Sqlite/DuckDB and a DSN for Postgres.
Driver_Kind :: enum {
	Sqlite,
	Postgres,
	Duckdb,
}

Schema :: struct {
	pkg_name:     string,
	dir:          string,
	tables:       [dynamic]Table_Spec,
	uses_time:    bool, // emit `import "core:time"` if any column is time.Time
	emit_structs: bool, // emit row struct decls (DB mode, unless struct_mode == None)
	struct_mode:  Struct_Mode,
}

// --- Shared helpers ---

// pascal_case converts a snake_case SQL name to a PascalCase identifier:
// "users" → "Users", "user_posts" → "UserPosts".
pascal_case :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	at_start := true
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '_' {
			at_start = true
			continue
		}
		if at_start && ch >= 'a' && ch <= 'z' {
			strings.write_byte(&b, ch - 32)
		} else {
			strings.write_byte(&b, ch)
		}
		at_start = false
	}
	return strings.to_string(b)
}

// singularize applies crude English singularization to a snake_case table
// name: categories → category, addresses → address, users → user. Words
// ending in "ss" (address) are left unchanged. Heuristic — override the
// result by editing the generated file or choosing -structs=none.
singularize :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) > 3 && strings.has_suffix(s, "ies") {
		return strings.concatenate({s[:len(s) - 3], "y"}, allocator)
	}
	if strings.has_suffix(s, "ses") ||
	   strings.has_suffix(s, "xes") ||
	   strings.has_suffix(s, "zes") ||
	   strings.has_suffix(s, "ches") ||
	   strings.has_suffix(s, "shes") {
		return strings.clone(s[:len(s) - 2], allocator)
	}
	if strings.has_suffix(s, "s") && !strings.has_suffix(s, "ss") {
		return strings.clone(s[:len(s) - 1], allocator)
	}
	return strings.clone(s, allocator)
}

// struct_name_for derives the row-struct name from the table name, falling
// back to "<Accessor>_Row" (with a warning) if singularization collides with
// the descriptor accessor.
struct_name_for :: proc(table_name, accessor: string) -> string {
	name := pascal_case(singularize(table_name))
	if name == accessor {
		fallback := strings.concatenate({accessor, "_Row"})
		fmt.eprintfln(
			"schemagen: row struct %q would collide with descriptor %q; using %q",
			name,
			accessor,
			fallback,
		)
		return fallback
	}
	return name
}

// unwrap_maybe turns "Maybe(X)" into ("X", true), other types into (t, false).
unwrap_maybe :: proc(t: string) -> (inner: string, is_maybe: bool) {
	if strings.has_prefix(t, "Maybe(") && strings.has_suffix(t, ")") {
		return strings.trim_space(t[len("Maybe("):len(t) - 1]), true
	}
	return t, false
}

// is_supported mirrors the scan layer's supported set (struct front-end).
is_supported :: proc(t: string) -> bool {
	switch t {
	case "i64",
	     "i32",
	     "i16",
	     "i8",
	     "int",
	     "u64",
	     "u32",
	     "u16",
	     "u8",
	     "uint",
	     "f64",
	     "f32",
	     "bool",
	     "string",
	     "[]byte",
	     "[]u8",
	     "time.Time":
		return true
	}
	return false
}

// --- Struct front-end ---

TABLE_ANNOTATION :: "+sql:table"

// table_name_of returns the table name from a `//+sql:table <name>` doc
// comment, or "" if the struct is not annotated.
table_name_of :: proc(docs: ^ast.Comment_Group) -> string {
	if docs == nil {return ""}
	for tok in docs.list {
		idx := strings.index(tok.text, TABLE_ANNOTATION)
		if idx < 0 {continue}
		rest := strings.trim_space(tok.text[idx + len(TABLE_ANNOTATION):])
		for r, i in rest {
			if r == ' ' || r == '\t' {
				return rest[:i]
			}
		}
		return rest
	}
	return ""
}

source_of :: proc(file: ^ast.File, node: ^ast.Node) -> string {
	return file.src[node.pos.offset:node.end.offset]
}

collect_struct :: proc(
	schema: ^Schema,
	file: ^ast.File,
	table_name: string,
	st: ^ast.Struct_Type,
) {
	spec := Table_Spec {
		name     = table_name,
		accessor = pascal_case(table_name),
	}

	if st.fields != nil {
		for f in st.fields.list {
			if f.type == nil {continue}
			// A Maybe(T) field marks the column nullable; the descriptor's
			// Column(T) uses the base type T.
			base, nullable := unwrap_maybe(strings.trim_space(source_of(file, f.type)))
			if !is_supported(base) {continue} 	// keep the descriptor compilable
			if base == "time.Time" {schema.uses_time = true}
			for n in f.names {
				ident, ok := n.derived.(^ast.Ident)
				if !ok {continue}
				append(
					&spec.columns,
					Column_Spec{name = ident.name, odin_type = base, nullable = nullable},
				)
			}
		}
	}

	append(&schema.tables, spec)
}

walk_file :: proc(schema: ^Schema, file: ^ast.File) {
	if schema.pkg_name == "" && file.pkg_decl != nil {
		schema.pkg_name = file.pkg_decl.name
	}

	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok {continue}

		table_name := table_name_of(vd.docs)
		if table_name == "" {continue}
		if len(vd.names) != 1 || len(vd.values) != 1 {continue}

		ident, _ := vd.names[0].derived.(^ast.Ident)
		if ident == nil {continue}

		st, st_ok := vd.values[0].derived.(^ast.Struct_Type)
		if !st_ok {continue}

		collect_struct(schema, file, table_name, st)
	}
}

front_end_structs :: proc(schema: ^Schema) -> bool {
	pkg, ok := parser.parse_package_from_path(schema.dir)
	if !ok {
		fmt.eprintfln("schemagen: failed to parse package at %s", schema.dir)
		return false
	}
	for _, file in pkg.files {
		walk_file(schema, file)
	}
	return true
}

// --- DB front-end ---

// is_datetime_decltype matches the driver: a decltype whose first token
// (case-insensitive) is DATETIME / TIMESTAMP / DATE / TIME maps to time.Time.
is_datetime_decltype :: proc(decltype: string) -> bool {
	end := 0
	for end < len(decltype) {
		ch := decltype[end]
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {break}
		end += 1
	}
	if end == 0 || end > 16 {return false}

	buf: [16]u8
	for i in 0 ..< end {
		ch := decltype[i]
		buf[i] = ch - 32 if ch >= 'a' && ch <= 'z' else ch
	}
	tok := string(buf[:end])
	return tok == "DATETIME" || tok == "TIMESTAMP" || tok == "DATE" || tok == "TIME"
}

// decltype_to_odin maps a SQLite declared column type to the Odin type the
// driver produces when scanning, via SQLite affinity rules + datetime
// detection. Returns ("", false) only for an empty decltype.
decltype_to_odin :: proc(decltype: string) -> (odin_type: string, ok: bool) {
	trimmed := strings.trim_space(decltype)
	if len(trimmed) == 0 {return "", false}
	if is_datetime_decltype(trimmed) {return "time.Time", true}

	up := strings.to_upper(trimmed, context.temp_allocator)
	switch {
	// JSON has NUMERIC affinity but is stored/returned as TEXT (json1) or, for
	// JSONB (SQLite 3.45+), as a BLOB. Handle it before the affinity rules so a
	// column declared JSON/JSONB doesn't fall through to the f64 default.
	case strings.contains(up, "JSONB"):
		return "[]byte", true
	case strings.contains(up, "JSON"):
		return "string", true
	// BOOLEAN has NUMERIC affinity but is stored/read as INTEGER 0/1; the scan
	// layer coerces i64 → bool. Check before INT (BOOL contains no "INT").
	case strings.contains(up, "BOOL"):
		return "bool", true
	case strings.contains(up, "INT"):
		return "i64", true
	case strings.contains(up, "CHAR"), strings.contains(up, "CLOB"), strings.contains(up, "TEXT"):
		return "string", true
	case strings.contains(up, "BLOB"):
		return "[]byte", true
	case strings.contains(up, "REAL"), strings.contains(up, "FLOA"), strings.contains(up, "DOUB"):
		return "f64", true
	case:
		return "f64", true // NUMERIC / unrecognized
	}
}

// list_tables returns the introspectable table names, sorted. It uses
// PRAGMA table_list (SQLite 3.37+) so it can skip views and the shadow tables
// that virtual tables (FTS5, R*Tree) create — keeping only real and virtual
// tables in the main schema. Sorting keeps generated output deterministic.
@(private = "file")
list_tables :: proc(db: ^sql.DB) -> ([dynamic]string, bool) {
	out := make([dynamic]string)
	rows, qerr := sql.query(db, "PRAGMA table_list")
	if qerr != nil {
		fmt.eprintfln("schemagen: PRAGMA table_list: %v", qerr)
		return out, false
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		name, schema, ttype: string
		for ci in 0 ..< rows.col_count {
			switch sql.row_col_name(&rows, ci) {
			case "name":
				if s, ok := sql.row_value(&rows, ci).(string); ok {name = s}
			case "schema":
				if s, ok := sql.row_value(&rows, ci).(string); ok {schema = s}
			case "type":
				if s, ok := sql.row_value(&rows, ci).(string); ok {ttype = s}
			}
		}
		if schema != "main" {continue} 	// skip temp / attached schemas
		if ttype != "table" && ttype != "virtual" {continue} 	// skip views, shadow tables
		if strings.has_prefix(name, "sqlite_") {continue} 	// skip internal tables
		append(&out, strings.clone(name))
	}
	// A mid-stream failure would silently truncate the table list — and thus the
	// generated schema. Treat it as a hard error rather than emitting a partial.
	if rerr := sql.rows_err(&rows); rerr != nil {
		fmt.eprintfln("schemagen: table_list: %v", rerr)
		return out, false
	}
	slice.sort(out[:])
	return out, true
}

front_end_db :: proc(schema: ^Schema, db_path: string) -> bool {
	db, oerr := sql.open(&sqlite.driver, db_path)
	if oerr != nil {
		fmt.eprintfln("schemagen: open %s: %v", db_path, oerr)
		return false
	}
	defer sql.close(db)

	schema.emit_structs = schema.struct_mode != .None

	table_names, ok := list_tables(db)
	if !ok {return false}

	for tname in table_names {
		spec := Table_Spec {
			name     = tname,
			accessor = pascal_case(tname),
		}
		if schema.emit_structs {
			spec.struct_name = struct_name_for(tname, spec.accessor)
		}

		// PRAGMA does not bind parameters; the name comes from sqlite_master.
		pragma := fmt.tprintf("PRAGMA table_info(\"%s\")", tname)
		rows, qerr := sql.query(db, pragma)
		if qerr != nil {
			fmt.eprintfln("schemagen: %s: %v", pragma, qerr)
			return false
		}

		for sql.next(&rows) {
			cname, ctype: string
			notnull, pk: i64
			for ci in 0 ..< rows.col_count {
				switch sql.row_col_name(&rows, ci) {
				case "name":
					if s, sok := sql.row_value(&rows, ci).(string); sok {cname = s}
				case "type":
					if s, sok := sql.row_value(&rows, ci).(string); sok {ctype = s}
				case "notnull":
					if v, sok := sql.row_value(&rows, ci).(i64); sok {notnull = v}
				case "pk":
					if v, sok := sql.row_value(&rows, ci).(i64); sok {pk = v}
				}
			}
			odin_type, supported := decltype_to_odin(ctype)
			if !supported {continue}
			if odin_type == "time.Time" {schema.uses_time = true}
			// A column is nullable unless it is NOT NULL or part of the
			// primary key (PK columns are implicitly non-null).
			nullable := notnull == 0 && pk == 0
			append(
				&spec.columns,
				Column_Spec {
					name = strings.clone(cname),
					odin_type = odin_type,
					nullable = nullable,
				},
			)
		}
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("schemagen: table_info(%q): %v", tname, rerr)
			sql.rows_close(&rows)
			return false
		}
		sql.rows_close(&rows)

		append(&schema.tables, spec)
	}

	return true
}

// --- DB front-end (PostgreSQL) ---

// pg_udt_to_odin maps a PostgreSQL `udt_name` (the canonical pg_type name from
// information_schema, e.g. int4/int8/float8/timestamptz/varchar) to the Odin
// type the driver produces at scan time. Mirrors the driver's OID mapping:
// int family → i64, float/numeric → f64, bytea → []byte, date/time family →
// time.Time, everything textual (incl. json/jsonb/uuid) → string. Unknown /
// user-defined types fall back to string, which the driver returns as text.
pg_udt_to_odin :: proc(udt: string) -> string {
	switch udt {
	case "int2", "int4", "int8", "oid":
		return "i64"
	case "float4", "float8", "numeric", "decimal":
		return "f64"
	case "bool":
		return "bool"
	case "bytea":
		return "[]byte"
	case "date", "time", "timetz", "timestamp", "timestamptz":
		return "time.Time"
	case:
		// text, varchar, bpchar, char, name, uuid, json, jsonb, citext, and any
		// type the driver hands back as text.
		return "string"
	}
}

// list_tables_pg returns the base tables in the `public` schema, sorted by the
// server for deterministic output. Views and other schemas are skipped, the
// same spirit as the SQLite front-end.
@(private = "file")
list_tables_pg :: proc(db: ^sql.DB) -> ([dynamic]string, bool) {
	out := make([dynamic]string)
	rows, qerr := sql.query(
		db,
		"SELECT table_name FROM information_schema.tables " +
		"WHERE table_schema = 'public' AND table_type = 'BASE TABLE' " +
		"ORDER BY table_name",
	)
	if qerr != nil {
		fmt.eprintfln("schemagen: list tables: %v", qerr)
		return out, false
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		if s, ok := sql.row_value(&rows, 0).(string); ok {
			append(&out, strings.clone(s))
		}
	}
	// Don't emit a schema from a silently truncated table list.
	if rerr := sql.rows_err(&rows); rerr != nil {
		fmt.eprintfln("schemagen: list tables: %v", rerr)
		return out, false
	}
	return out, true
}

front_end_db_postgres :: proc(schema: ^Schema, dsn: string) -> bool {
	db, oerr := sql.open(&postgres.driver, dsn)
	if oerr != nil {
		fmt.eprintfln("schemagen: open postgres %q: %v", dsn, oerr)
		return false
	}
	defer sql.close(db)

	schema.emit_structs = schema.struct_mode != .None

	table_names, ok := list_tables_pg(db)
	if !ok {return false}

	for tname in table_names {
		spec := Table_Spec {
			name     = tname,
			accessor = pascal_case(tname),
		}
		if schema.emit_structs {
			spec.struct_name = struct_name_for(tname, spec.accessor)
		}

		rows, qerr := sql.query(
			db,
			"SELECT column_name, udt_name, is_nullable " +
			"FROM information_schema.columns " +
			"WHERE table_schema = 'public' AND table_name = ? " +
			"ORDER BY ordinal_position",
			tname,
		)
		if qerr != nil {
			fmt.eprintfln("schemagen: columns for %q: %v", tname, qerr)
			return false
		}

		for sql.next(&rows) {
			cname, udt, is_nullable: string
			for ci in 0 ..< rows.col_count {
				switch sql.row_col_name(&rows, ci) {
				case "column_name":
					if s, sok := sql.row_value(&rows, ci).(string); sok {cname = s}
				case "udt_name":
					if s, sok := sql.row_value(&rows, ci).(string); sok {udt = s}
				case "is_nullable":
					if s, sok := sql.row_value(&rows, ci).(string); sok {is_nullable = s}
				}
			}
			odin_type := pg_udt_to_odin(udt)
			if odin_type == "time.Time" {schema.uses_time = true}
			// information_schema already reports is_nullable = 'NO' for primary-key
			// and NOT NULL columns, so this single flag is authoritative.
			nullable := is_nullable == "YES"
			append(
				&spec.columns,
				Column_Spec {
					name = strings.clone(cname),
					odin_type = odin_type,
					nullable = nullable,
				},
			)
		}
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("schemagen: columns for %q: %v", tname, rerr)
			sql.rows_close(&rows)
			return false
		}
		sql.rows_close(&rows)

		append(&schema.tables, spec)
	}

	return true
}

// --- DB front-end (DuckDB) — opt-in, see DUCKDB_INTROSPECT ---

when DUCKDB_INTROSPECT {
	// duckdb_type_to_odin maps a DuckDB `data_type` (from information_schema, e.g.
	// INTEGER / BIGINT / HUGEINT / DECIMAL(18,3) / VARCHAR / TIMESTAMP WITH TIME
	// ZONE / UUID) to the Odin type the driver produces at scan time. ok=false
	// means the column is a composite (LIST/ARRAY/STRUCT/MAP/UNION) that can't be
	// represented as a single scalar field — the caller skips it.
	duckdb_type_to_odin :: proc(dt: string) -> (odin_type: string, ok: bool) {
		up := strings.to_upper(strings.trim_space(dt), context.temp_allocator)
		// Composites scan into []T / structs / maps, not a single field — skip.
		if strings.contains(up, "[") ||
		   strings.has_prefix(up, "STRUCT(") ||
		   strings.has_prefix(up, "MAP(") ||
		   strings.has_prefix(up, "UNION(") {
			return "", false
		}
		switch {
		case up == "BOOLEAN":
			return "bool", true
		case up == "TINYINT", up == "SMALLINT", up == "INTEGER", up == "BIGINT",
		     up == "UTINYINT", up == "USMALLINT", up == "UINTEGER":
			return "i64", true
		case up == "UBIGINT", up == "HUGEINT":
			return "i128", true
		case up == "UHUGEINT":
			return "u128", true
		case up == "FLOAT", up == "REAL", up == "DOUBLE":
			return "f64", true
		case strings.has_prefix(up, "DECIMAL"), strings.has_prefix(up, "NUMERIC"):
			return "f64", true // driver maps the DECIMAL column type to f64
		case strings.has_prefix(up, "VARCHAR"), strings.has_prefix(up, "CHAR"),
		     up == "TEXT", up == "STRING":
			return "string", true
		case up == "BLOB", up == "BYTEA":
			return "[]byte", true
		case strings.has_prefix(up, "TIMESTAMP"), up == "DATE", strings.has_prefix(up, "TIME"):
			return "time.Time", true
		case up == "UUID", up == "INTERVAL", up == "BIT", up == "VARINT":
			return "string", true
		case:
			// ENUM columns report their type name; the driver scans an enum as its
			// label string. Unknown types likewise fall back to string.
			return "string", true
		}
	}

	list_tables_duckdb :: proc(db: ^sql.DB) -> ([dynamic]string, bool) {
		out := make([dynamic]string)
		rows, qerr := sql.query(
			db,
			"SELECT table_name FROM information_schema.tables " +
			"WHERE table_schema = 'main' AND table_type = 'BASE TABLE' " +
			"ORDER BY table_name",
		)
		if qerr != nil {
			fmt.eprintfln("schemagen: list tables: %v", qerr)
			return out, false
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			if s, ok := sql.row_value(&rows, 0).(string); ok {
				append(&out, strings.clone(s))
			}
		}
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("schemagen: list tables: %v", rerr)
			return out, false
		}
		return out, true
	}

	front_end_db_duckdb :: proc(schema: ^Schema, db_path: string) -> bool {
		db, oerr := sql.open(&duck.driver, db_path)
		if oerr != nil {
			fmt.eprintfln("schemagen: open duckdb %q: %v", db_path, oerr)
			return false
		}
		defer sql.close(db)
		// Pin one connection: a pooled :memory: DSN otherwise gives each query its
		// own isolated database (and a single connection keeps file DBs simple).
		sql.set_max_open_conns(db, 1)

		schema.emit_structs = schema.struct_mode != .None

		table_names, ok := list_tables_duckdb(db)
		if !ok {return false}

		for tname in table_names {
			spec := Table_Spec {
				name     = tname,
				accessor = pascal_case(tname),
			}
			if schema.emit_structs {
				spec.struct_name = struct_name_for(tname, spec.accessor)
			}

			rows, qerr := sql.query(
				db,
				"SELECT column_name, data_type, is_nullable " +
				"FROM information_schema.columns " +
				"WHERE table_schema = 'main' AND table_name = ? " +
				"ORDER BY ordinal_position",
				tname,
			)
			if qerr != nil {
				fmt.eprintfln("schemagen: columns for %q: %v", tname, qerr)
				return false
			}

			for sql.next(&rows) {
				cname, dtype, is_nullable: string
				for ci in 0 ..< rows.col_count {
					switch sql.row_col_name(&rows, ci) {
					case "column_name":
						if s, sok := sql.row_value(&rows, ci).(string); sok {cname = s}
					case "data_type":
						if s, sok := sql.row_value(&rows, ci).(string); sok {dtype = s}
					case "is_nullable":
						if s, sok := sql.row_value(&rows, ci).(string); sok {is_nullable = s}
					}
				}
				odin_type, supported := duckdb_type_to_odin(dtype)
				if !supported {
					fmt.eprintfln(
						"schemagen: %s.%s: skipping composite column of type %q (no scalar mapping)",
						tname,
						cname,
						dtype,
					)
					continue
				}
				if odin_type == "time.Time" {schema.uses_time = true}
				append(
					&spec.columns,
					Column_Spec {
						name = strings.clone(cname),
						odin_type = odin_type,
						nullable = is_nullable == "YES",
					},
				)
			}
			if rerr := sql.rows_err(&rows); rerr != nil {
				fmt.eprintfln("schemagen: columns for %q: %v", tname, rerr)
				sql.rows_close(&rows)
				return false
			}
			sql.rows_close(&rows)

			append(&schema.tables, spec)
		}

		return true
	}
}

// --- Emit ---

@(private = "file")
ws :: proc(b: ^strings.Builder, parts: ..string) {
	for p in parts {strings.write_string(b, p)}
}

emit :: proc(schema: ^Schema) -> string {
	b := strings.builder_make()

	ws(&b, "// Code generated by tools/schemagen. DO NOT EDIT.\n")
	ws(&b, "package ", schema.pkg_name, "\n\n")

	if schema.uses_time {ws(&b, "import \"core:time\"\n")}
	ws(&b, "import sb \"database:sqlbuilder\"\n\n")

	if schema.emit_structs {
		for i in 0 ..< len(schema.tables) {
			emit_struct(&b, &schema.tables[i])
			ws(&b, "\n")
		}
	}

	for i in 0 ..< len(schema.tables) {
		emit_table(&b, &schema.tables[i])
		ws(&b, "\n")
	}

	return strings.to_string(b)
}

emit_struct :: proc(b: ^strings.Builder, tbl: ^Table_Spec) {
	ws(b, "//+sql:scan\n") // let scangen produce a concrete scanner
	ws(b, tbl.struct_name, " :: struct {\n")
	for col in tbl.columns {
		if col.nullable {
			ws(b, "\t", col.name, ": Maybe(", col.odin_type, "),\n")
		} else {
			ws(b, "\t", col.name, ": ", col.odin_type, ",\n")
		}
	}
	ws(b, "}\n")
}

emit_table :: proc(b: ^strings.Builder, tbl: ^Table_Spec) {
	// Anonymous struct type.
	ws(b, tbl.accessor, " := struct {\n")
	ws(b, "\t_info: sb.Table_Info,\n")
	for col in tbl.columns {
		ws(b, "\t", col.name, ": sb.Column(", col.odin_type, "),\n")
	}
	ws(b, "}{\n")

	// Struct literal value.
	ws(b, "\t_info = {name = \"", tbl.name, "\"},\n")
	for col in tbl.columns {
		ws(
			b,
			"\t",
			col.name,
			" = {base = {table = \"",
			tbl.name,
			"\", name = \"",
			col.name,
			"\", type_id = ",
			col.odin_type,
		)
		if col.nullable {ws(b, ", nullable = true")}
		ws(b, "}},\n")
	}
	ws(b, "}\n")
}

// --- Driver ---

// detect_pkg returns the Odin package name declared in `dir`, or "main" if the
// directory has no parseable package yet (e.g. a fresh DB-mode output dir).
detect_pkg :: proc(dir: string) -> string {
	pkg, ok := parser.parse_package_from_path(dir)
	if ok {
		for _, file in pkg.files {
			if file.pkg_decl != nil {return file.pkg_decl.name}
		}
	}
	return "main"
}

// Options is the schemagen command line, parsed declaratively by core:flags.
// `driver` and `structs` are validated by hand (not enum-parsed) to keep the
// lowercase `-driver=postgres` / `-structs=none` spellings exactly.
Options :: struct {
	dir:    
	string `args:"pos=0,required" usage:"package directory to write schema.gen.odin into"`,
	db:
	string `args:"name=db"        usage:"introspect this database instead of structs (SQLite/DuckDB file path, or a DSN with -driver=postgres)"`,
	driver:
	string `args:"name=driver"    usage:"DB driver for -db: sqlite (default), postgres, or duckdb (build with -define:SCHEMAGEN_DUCKDB=true)"`,
	pkg:    
	string `args:"name=package"   usage:"override the generated package name"`,
	structs:
	string `args:"name=structs"  usage:"DB-mode row structs: singular (default) or none"`,
}

// run parses args and generates the descriptors, returning a process exit
// code. `prog` is the program name shown in usage ("schemagen" standalone,
// "odb schema" under the unified CLI). Exposed for the `odb` dispatcher.
run :: proc(prog: string, args: []string) -> int {
	opt: Options
	program_args := make([]string, len(args) + 1, context.temp_allocator)
	program_args[0] = prog
	copy(program_args[1:], args)
	flags.parse_or_exit(&opt, program_args, .Unix) // accepts `-flag value` and `-flag=value`; handles -h/usage/errors

	driver_kind := Driver_Kind.Sqlite
	switch opt.driver {
	case "", "sqlite":
		driver_kind = .Sqlite
	case "postgres", "pg":
		driver_kind = .Postgres
	case "duckdb", "duck":
		driver_kind = .Duckdb
	case:
		fmt.eprintfln(
			"schemagen: -driver must be 'sqlite', 'postgres', or 'duckdb', got %q",
			opt.driver,
		)
		return 2
	}

	struct_mode := Struct_Mode.Singular
	switch opt.structs {
	case "", "singular":
		struct_mode = .Singular
	case "none":
		struct_mode = .None
	case:
		fmt.eprintfln("schemagen: -structs must be 'singular' or 'none', got %q", opt.structs)
		return 2
	}

	if (driver_kind == .Postgres || driver_kind == .Duckdb) && opt.db == "" {
		fmt.eprintfln(
			"schemagen: -driver=%s requires -db (the struct front-end is driver-agnostic)",
			opt.driver,
		)
		return 2
	}

	schema := Schema {
		dir         = opt.dir,
		struct_mode = struct_mode,
	}

	if opt.db != "" {
		schema.pkg_name = opt.pkg if opt.pkg != "" else detect_pkg(opt.dir)
		ok: bool
		switch driver_kind {
		case .Sqlite:
			ok = front_end_db(&schema, opt.db)
		case .Postgres:
			ok = front_end_db_postgres(&schema, opt.db)
		case .Duckdb:
			when DUCKDB_INTROSPECT {
				ok = front_end_db_duckdb(&schema, opt.db)
			} else {
				fmt.eprintln(
					"schemagen: DuckDB introspection isn't compiled in. " +
					"Rebuild with -define:SCHEMAGEN_DUCKDB=true and set the libduckdb loader path.",
				)
				return 2
			}
		}
		if !ok {return 1}
	} else {
		if !front_end_structs(&schema) {return 1}
		if opt.pkg != "" {schema.pkg_name = opt.pkg}
	}

	out, _ := filepath.join({opt.dir, "schema.gen.odin"}, context.allocator)

	if len(schema.tables) == 0 {
		if opt.db != "" {
			fmt.printfln("schemagen: no tables found in %s", opt.db)
		} else {
			fmt.printfln("schemagen: no `//%s` annotations found in %s", TABLE_ANNOTATION, opt.dir)
		}
		os.remove(out)
		return 0
	}

	src := emit(&schema)
	if werr := os.write_entire_file(out, transmute([]u8)src); werr != nil {
		fmt.eprintfln("schemagen: write %s: %v", out, werr)
		return 1
	}

	fmt.printfln("schemagen: wrote %s (%d table(s))", out, len(schema.tables))
	return 0
}

main :: proc() {
	os.exit(run(os.args[0], os.args[1:]))
}

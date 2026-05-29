// schemagen — generate typed column descriptors (and, in DB mode, row
// structs) for the sqlbuilder typed layer, one descriptor object per table.
//
// Usage:
//   odin run tools/schemagen -- <pkg-dir>                            # struct front-end
//   odin run tools/schemagen -- -db=<path> [-package=<n>] [-structs=singular|none] <pkg-dir>
//
// schemagen is built around an internal `Schema` model that decouples the
// *source* of the schema from the *emitted* code. Two front-ends populate the
// same `Schema` and share one `emit`:
//
//   - front_end_structs: reads annotated Odin structs (the struct is the
//     source of truth; the row struct already exists, so only descriptors are
//     emitted). A `Maybe(T)` field marks the column nullable and maps the
//     descriptor to `Column(T)`.
//   - front_end_db: opens a database via the driver and reads its schema (the
//     database is the source of truth, so row structs AND descriptors are
//     emitted, unless -structs=none).
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

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import sql "database:sql"
import sqlite "database:drivers/sqlite"

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
	case "i64", "i32", "i16", "i8", "int",
	     "u64", "u32", "u16", "u8", "uint",
	     "f64", "f32", "bool", "string",
	     "[]byte", "[]u8", "time.Time":
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

collect_struct :: proc(schema: ^Schema, file: ^ast.File, table_name: string, st: ^ast.Struct_Type) {
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
			if !is_supported(base) {continue} // keep the descriptor compilable
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
	defer sql.close_rows(&rows)

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
		if schema != "main" {continue} // skip temp / attached schemas
		if ttype != "table" && ttype != "virtual" {continue} // skip views, shadow tables
		if strings.has_prefix(name, "sqlite_") {continue} // skip internal tables
		append(&out, strings.clone(name))
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
				Column_Spec{name = strings.clone(cname), odin_type = odin_type, nullable = nullable},
			)
		}
		sql.close_rows(&rows)

		append(&schema.tables, spec)
	}

	return true
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
		ws(b, "\t", col.name, " = {base = {table = \"", tbl.name, "\", name = \"", col.name, "\", type_id = ", col.odin_type)
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

main :: proc() {
	db_path := ""
	pkg_override := ""
	dir := ""
	struct_mode := Struct_Mode.Singular

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-db="):
			db_path = arg[len("-db="):]
		case strings.has_prefix(arg, "-package="):
			pkg_override = arg[len("-package="):]
		case strings.has_prefix(arg, "-structs="):
			switch arg[len("-structs="):] {
			case "singular":
				struct_mode = .Singular
			case "none":
				struct_mode = .None
			case:
				fmt.eprintfln("schemagen: -structs must be 'singular' or 'none', got %q", arg)
				os.exit(2)
			}
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("schemagen: unknown flag %q", arg)
			os.exit(2)
		case:
			dir = arg
		}
	}

	if dir == "" {
		fmt.eprintln(
			"usage: schemagen [-db=<path>] [-package=<name>] [-structs=singular|none] <pkg-dir>",
		)
		os.exit(2)
	}

	schema := Schema{dir = dir, struct_mode = struct_mode}

	if db_path != "" {
		schema.pkg_name = pkg_override if pkg_override != "" else detect_pkg(dir)
		if !front_end_db(&schema, db_path) {os.exit(1)}
	} else {
		if !front_end_structs(&schema) {os.exit(1)}
		if pkg_override != "" {schema.pkg_name = pkg_override}
	}

	out, _ := filepath.join({dir, "schema.gen.odin"})

	if len(schema.tables) == 0 {
		if db_path != "" {
			fmt.printfln("schemagen: no tables found in %s", db_path)
		} else {
			fmt.printfln("schemagen: no `//%s` annotations found in %s", TABLE_ANNOTATION, dir)
		}
		os.remove(out)
		return
	}

	src := emit(&schema)
	if werr := os.write_entire_file(out, transmute([]u8)src); werr != nil {
		fmt.eprintfln("schemagen: write %s: %v", out, werr)
		os.exit(1)
	}

	fmt.printfln("schemagen: wrote %s (%d table(s))", out, len(schema.tables))
}

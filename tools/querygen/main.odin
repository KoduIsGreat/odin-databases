// querygen — generate typed data-access procedures from annotated `.sql`
// query files (sqlc-style), for the `database:sql` runtime.
//
// Usage:
//   odin run tools/querygen -- -db=<schema.db> <sql-dir> <out-dir> [-driver=<d>] [-package=<name>]
//
//   <sql-dir>   directory of `.sql` files with annotated queries
//   <out-dir>   package directory to write <out-dir>/queries.gen.odin into
//   -db=        a database already loaded with the schema (used only at
//               generation time to describe each query's result columns):
//               a file path for sqlite/duckdb, a DSN for postgres
//   -driver=    sqlite (default), postgres, or duckdb (build with
//               -define:QUERYGEN_DUCKDB=true). Selects the describe driver and
//               the placeholder dialect: `?` for sqlite/duckdb, `$N` for postgres
//   -package=   package name for the generated file (default: inferred from
//               <out-dir>, falling back to its basename)
//
// Query files annotate each statement with a header comment:
//
//   -- name: GetUser :one
//   -- arg: id i64
//   SELECT id, name, age FROM users WHERE id = ?;
//
// where the cardinality is one of:
//
//   :one    a single row   → returns (<Name>Row, Error)
//   :many   zero+ rows      → returns ([]<Name>Row, Error)
//   :exec   no rows         → returns (sql.Result, Error)
//
// `-- arg:` lines name the placeholders in order; their types are the proc's
// parameter types (declared, not inferred — see note below). Result column types
// ARE inferred: querygen runs each :one/:many query against -db (inside a
// rolled-back transaction) with zero-valued arguments and reads the result
// column metadata (column name + Odin type) from the driver — no SQL parser.
//
// Placeholders follow the driver dialect: `?` for sqlite/duckdb, `$N` for
// postgres. Parameter types are declared rather than inferred because SQLite
// cannot report them statically; keeping it uniform across drivers means one
// annotation format regardless of target.
//
// Limitations (this slice): one statement per query; results map to their base
// Odin type (no Maybe(T) for nullable columns). A result column with no static
// type (an expression like COUNT(*) on SQLite) is an error — alias/CAST it, or
// select table columns.
package querygen

import "core:flags"
import "core:fmt"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import postgres "database:drivers/postgres"
import sqlite "database:drivers/sqlite"
import sql "database:sql"

// DuckDB describe links libduckdb (a fetched shared lib), so it is opt-in at
// build time — mirroring tools/schemagen. Enable with
// `-define:QUERYGEN_DUCKDB=true` (and set the libduckdb loader path). `duck` is
// referenced only under `when QUERYGEN_DUCKDB`, so a default build neither links
// nor requires libduckdb.
QUERYGEN_DUCKDB :: #config(QUERYGEN_DUCKDB, false)
import duck "database:drivers/duckdb"

// --- Model ---

Cardinality :: enum {
	One,
	Many,
	Exec,
}

// Placeholder_Style is the parameter-placeholder dialect of the target driver:
// `?` (SQLite, DuckDB) or `$N` (PostgreSQL). It selects how placeholders are
// counted and validated against `-- arg:` declarations.
Placeholder_Style :: enum {
	Question,
	Dollar,
}

Arg :: struct {
	name: string,
	type: string, // Odin type as written in the `-- arg:` annotation
}

Result_Col :: struct {
	name: string, // result column name → generated struct field
	type: string, // Odin type, inferred from the driver's column metadata
}

Query_Spec :: struct {
	name:    string, // e.g. "GetUser" — also the generated proc name
	card:    Cardinality,
	sql:     string, // statement body, no trailing ';'
	args:    [dynamic]Arg,
	results: [dynamic]Result_Col, // filled by describe (empty for :exec)
}

// --- Parsing (pure: operates on file text) ---

Parse_Error :: struct {
	line: int, // 1-based; 0 if not line-specific
	msg:  string,
}

NAME_PREFIX :: "-- name:"
ARG_PREFIX :: "-- arg:"

// parse_queries turns the text of one `.sql` file into query specs. The
// returned specs (and their dynamic arrays) are allocated with `allocator`.
parse_queries :: proc(
	src: string,
	style := Placeholder_Style.Question,
	allocator := context.allocator,
) -> (
	specs: [dynamic]Query_Spec,
	perr: Maybe(Parse_Error),
) {
	specs = make([dynamic]Query_Spec, allocator)

	body: strings.Builder
	strings.builder_init(&body, context.temp_allocator)
	have_cur := false

	// flush finalizes the in-progress spec's SQL body.
	flush :: proc(specs: ^[dynamic]Query_Spec, body: ^strings.Builder, have_cur: bool) {
		if !have_cur {return}
		s := strings.trim_space(strings.to_string(body^))
		s = strings.trim_right(s, ";")
		cur := &specs[len(specs) - 1]
		cur.sql = strings.clone(strings.trim_space(s), specs.allocator)
	}

	lines := strings.split_lines(src, context.temp_allocator)
	for raw, i in lines {
		lineno := i + 1
		t := strings.trim_space(raw)

		if strings.has_prefix(t, NAME_PREFIX) {
			flush(&specs, &body, have_cur)
			strings.builder_reset(&body)

			rest := strings.trim_space(t[len(NAME_PREFIX):])
			fields := strings.fields(rest, context.temp_allocator)
			if len(fields) < 2 {
				return specs, Parse_Error{lineno, "expected `-- name: <Name> :one|:many|:exec`"}
			}
			name := fields[0]
			if !is_ident(name) {
				return specs, Parse_Error{lineno, fmt.tprintf("invalid query name %q", name)}
			}
			card, ok := parse_card(fields[1])
			if !ok {
				return specs, Parse_Error {
					lineno,
					fmt.tprintf("invalid cardinality %q (want :one, :many, or :exec)", fields[1]),
				}
			}
			append(&specs, Query_Spec{name = strings.clone(name, allocator), card = card})
			have_cur = true
			continue
		}

		if strings.has_prefix(t, ARG_PREFIX) {
			if !have_cur {
				return specs, Parse_Error{lineno, "`-- arg:` before any `-- name:`"}
			}
			rest := strings.trim_space(t[len(ARG_PREFIX):])
			fields := strings.fields(rest, context.temp_allocator)
			if len(fields) != 2 {
				return specs, Parse_Error{lineno, "expected `-- arg: <name> <odin-type>`"}
			}
			if !is_ident(fields[0]) {
				return specs, Parse_Error{lineno, fmt.tprintf("invalid arg name %q", fields[0])}
			}
			if !is_supported_type(fields[1]) {
				return specs, Parse_Error {
					lineno,
					fmt.tprintf("unsupported arg type %q", fields[1]),
				}
			}
			cur := &specs[len(specs) - 1]
			append(
				&cur.args,
				Arg{strings.clone(fields[0], allocator), strings.clone(fields[1], allocator)},
			)
			continue
		}

		if strings.has_prefix(t, "--") || t == "" {
			continue // other comment, or blank
		}

		// SQL body line.
		if !have_cur {
			return specs, Parse_Error{lineno, "SQL before any `-- name:` header"}
		}
		if strings.builder_len(body) > 0 {
			strings.write_byte(&body, '\n')
		}
		strings.write_string(&body, raw)
	}
	flush(&specs, &body, have_cur)

	// Validate placeholder counts against declared args.
	for &s in specs {
		n, bad := count_placeholders(s.sql, style)
		if bad {
			other := style == .Question ? "$N" : "?"
			return specs, Parse_Error {
				0,
				fmt.tprintf(
					"query %q: unexpected %s placeholder for the target dialect",
					s.name,
					other,
				),
			}
		}
		if n != len(s.args) {
			return specs, Parse_Error {
				0,
				fmt.tprintf(
					"query %q: %d placeholder(s) but %d `-- arg:` declared",
					s.name,
					n,
					len(s.args),
				),
			}
		}
	}
	return specs, nil
}

// destroy_specs frees a specs slice and everything parse_queries / describe
// cloned into `allocator`.
destroy_specs :: proc(specs: [dynamic]Query_Spec, allocator := context.allocator) {
	for s in specs {
		delete(s.name, allocator)
		delete(s.sql, allocator)
		for a in s.args {
			delete(a.name, allocator)
			delete(a.type, allocator)
		}
		delete(s.args)
		for r in s.results {
			delete(r.name, allocator)
			delete(r.type, allocator)
		}
		delete(s.results)
	}
	delete(specs)
}

parse_card :: proc(tok: string) -> (Cardinality, bool) {
	switch tok {
	case ":one":
		return .One, true
	case ":many":
		return .Many, true
	case ":exec":
		return .Exec, true
	}
	return {}, false
}

// count_placeholders counts the parameters a SQL string references, skipping
// string literals ('...'), quoted identifiers ("..."), line comments (-- to EOL)
// and block comments (/* */). For .Question it counts `?` occurrences; for
// .Dollar it returns the highest `$N` index (Postgres params are 1-based and may
// repeat). `bad` is set if a placeholder of the *other* style is seen.
count_placeholders :: proc(
	sql_str: string,
	style := Placeholder_Style.Question,
) -> (
	count: int,
	bad: bool,
) {
	max_dollar := 0
	i := 0
	n := len(sql_str)
	for i < n {
		c := sql_str[i]
		switch c {
		case '\'', '"':
			quote := c
			i += 1
			for i < n {
				if sql_str[i] == quote {
					if i + 1 < n && sql_str[i + 1] == quote {
						i += 2 // doubled quote escape
						continue
					}
					i += 1
					break
				}
				i += 1
			}
		case '-':
			if i + 1 < n && sql_str[i + 1] == '-' {
				for i < n && sql_str[i] != '\n' {i += 1}
			} else {
				i += 1
			}
		case '/':
			if i + 1 < n && sql_str[i + 1] == '*' {
				i += 2
				for i + 1 < n && !(sql_str[i] == '*' && sql_str[i + 1] == '/') {i += 1}
				i += 2
			} else {
				i += 1
			}
		case '?':
			if style == .Question {
				count += 1
			} else {
				bad = true
			}
			i += 1
		case '$':
			j := i + 1
			for j < n && sql_str[j] >= '0' && sql_str[j] <= '9' {j += 1}
			if j > i + 1 { // `$` followed by digits
				if style == .Dollar {
					if idx, ok := strconv.parse_int(sql_str[i + 1:j]); ok && idx > max_dollar {
						max_dollar = idx
					}
				} else {
					bad = true
				}
				i = j
			} else {
				i += 1
			}
		case:
			i += 1
		}
	}
	if style == .Dollar {
		count = max_dollar
	}
	return
}

// --- Describe (impure: runs queries against a schema-loaded DB) ---

// describe fills each :one/:many spec's result columns by running the query
// with zero-valued arguments and reading the driver's column metadata (uniform
// across drivers: SQLite via decltype affinity, Postgres via OID, DuckDB via
// logical type). Returns "" on success, or a human-readable error message.
//
// Each query runs inside a transaction that is rolled back, so a query
// mis-annotated as :one/:many but actually mutating (e.g. INSERT ... RETURNING)
// cannot change the database at generation time.
describe :: proc(db: ^sql.DB, specs: []Query_Spec, allocator := context.allocator) -> string {
	for &s in specs {
		if s.card == .Exec {continue}

		zargs := make([]sql.Value, len(s.args), context.temp_allocator)
		for a, i in s.args {
			zargs[i] = zero_value(a.type)
		}

		tx, terr := sql.begin(db)
		if terr != nil {
			return fmt.tprintf("query %q: begin: %v", s.name, terr)
		}
		rows, qerr := sql.query(&tx, s.sql, ..zargs)
		if qerr != nil {
			sql.rollback(&tx)
			return fmt.tprintf("query %q: describe failed: %v", s.name, qerr)
		}

		msg := collect_results(&s, &rows, allocator)
		sql.rows_close(&rows)
		sql.rollback(&tx)
		if msg != "" {
			return msg
		}
	}
	return ""
}

// collect_results reads the result column metadata for one query into s.results,
// returning "" on success or an error message.
collect_results :: proc(
	s: ^Query_Spec,
	rows: ^sql.Rows,
	allocator := context.allocator,
) -> string {
	cols := sql.columns(rows)
	if len(cols) == 0 {
		return fmt.tprintf("query %q: :%v query returns no columns", s.name, s.card)
	}
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for col, ci in cols {
		tname, ok := typeid_to_odin(col.type_id)
		if !ok {
			return fmt.tprintf(
				"query %q: cannot infer a type for result column %q (index %d) — the driver reports no static type; alias or CAST it, or select a table column",
				s.name,
				col.name,
				ci,
			)
		}
		if !is_ident(col.name) {
			return fmt.tprintf(
				"query %q: result column %q (index %d) is not a valid identifier — alias it with `AS`",
				s.name,
				col.name,
				ci,
			)
		}
		if seen[col.name] {
			return fmt.tprintf(
				"query %q: duplicate result column %q — alias one with `AS`",
				s.name,
				col.name,
			)
		}
		seen[col.name] = true
		append(
			&s.results,
			Result_Col{strings.clone(col.name, allocator), strings.clone(tname, allocator)},
		)
	}
	return ""
}

zero_value :: proc(odin_type: string) -> sql.Value {
	switch odin_type {
	case "f64", "f32":
		return f64(0)
	case "bool":
		return false
	case "string":
		return ""
	case "[]byte", "[]u8":
		return []byte{}
	case "time.Time":
		return time.Time{}
	case:
		return i64(0) // integer family
	}
}

typeid_to_odin :: proc(t: typeid) -> (string, bool) {
	switch t {
	case typeid_of(i64):
		return "i64", true
	case typeid_of(f64):
		return "f64", true
	case typeid_of(bool):
		return "bool", true
	case typeid_of(string):
		return "string", true
	case typeid_of([]u8):
		return "[]byte", true
	case typeid_of(time.Time):
		return "time.Time", true
	case typeid_of(i128):
		return "i128", true
	case typeid_of(u128):
		return "u128", true
	}
	return "", false // 0 / unknown (expression column with no declared type)
}

// --- Emit ---

emit :: proc(pkg_name: string, specs: []Query_Spec, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w :: strings.write_string

	w(&b, "// Code generated by tools/querygen. DO NOT EDIT.\n")
	w(&b, "package ")
	w(&b, pkg_name)
	w(&b, "\n\n")

	if specs_use_time(specs) {
		w(&b, "import \"core:time\"\n")
	}
	w(&b, "import sql \"database:sql\"\n\n")

	for &s, i in specs {
		if i > 0 {w(&b, "\n")}
		emit_query(&b, &s)
	}
	return strings.to_string(b)
}

emit_query :: proc(b: ^strings.Builder, s: ^Query_Spec) {
	w :: strings.write_string

	// SQL constant.
	w(b, s.name)
	w(b, "_sql :: ")
	emit_string(b, s.sql)
	w(b, "\n\n")

	// Result row struct (one/many).
	if s.card != .Exec {
		w(b, s.name)
		w(b, "Row :: struct {\n")
		for r in s.results {
			fmt.sbprintf(b, "\t%s: %s,\n", r.name, r.type)
		}
		w(b, "}\n\n")
	}

	// Proc signature.
	w(b, s.name)
	w(b, " :: proc(db: ^sql.DB")
	for a in s.args {
		fmt.sbprintf(b, ", %s: %s", a.name, a.type)
	}
	if s.card == .Many {
		w(b, ", allocator := context.allocator")
	}
	w(b, ", loc := #caller_location) -> ")

	switch s.card {
	case .One:
		fmt.sbprintf(b, "(%sRow, sql.Error) {{\n", s.name)
		fmt.sbprintf(b, "\trow := sql.query_row(db, %s_sql", s.name)
		emit_call_args(b, s.args[:])
		w(b, ", loc = loc)\n")
		w(b, "\tdefer sql.close_row(&row)\n")
		fmt.sbprintf(b, "\tout: %sRow\n", s.name)
		w(b, "\terr := sql.scan(&row")
		emit_scan_dests(b, s.results[:])
		w(b, ")\n")
		w(b, "\treturn out, err\n")
		w(b, "}\n")
	case .Many:
		fmt.sbprintf(b, "([]%sRow, sql.Error) {{\n", s.name)
		fmt.sbprintf(b, "\trows, qerr := sql.query(db, %s_sql", s.name)
		emit_call_args(b, s.args[:])
		w(b, ", loc = loc)\n")
		w(b, "\tif qerr != nil {\n\t\treturn nil, qerr\n\t}\n")
		w(b, "\tdefer sql.rows_close(&rows)\n")
		fmt.sbprintf(b, "\tout := make([dynamic]%sRow, allocator)\n", s.name)
		w(b, "\tfor sql.next(&rows) {\n")
		fmt.sbprintf(b, "\t\tr: %sRow\n", s.name)
		w(b, "\t\tif serr := sql.scan(&rows")
		emit_scan_dests_named(b, s.results[:], "r")
		w(b, "); serr != nil {\n")
		w(b, "\t\t\tdelete(out)\n\t\t\treturn nil, serr\n\t\t}\n")
		w(b, "\t\tappend(&out, r)\n")
		w(b, "\t}\n")
		w(b, "\tif rerr := sql.rows_err(&rows); rerr != nil {\n")
		w(b, "\t\tdelete(out)\n\t\treturn nil, rerr\n\t}\n")
		w(b, "\treturn out[:], nil\n")
		w(b, "}\n")
	case .Exec:
		fmt.sbprintf(b, "(sql.Result, sql.Error) {{\n\treturn sql.exec(db, %s_sql", s.name)
		emit_call_args(b, s.args[:])
		w(b, ", loc = loc)\n}\n")
	}
}

emit_call_args :: proc(b: ^strings.Builder, args: []Arg) {
	for a in args {
		fmt.sbprintf(b, ", %s", a.name)
	}
}

emit_scan_dests :: proc(b: ^strings.Builder, results: []Result_Col) {
	emit_scan_dests_named(b, results, "out")
}

emit_scan_dests_named :: proc(b: ^strings.Builder, results: []Result_Col, recv: string) {
	for r in results {
		fmt.sbprintf(b, ", &%s.%s", recv, r.name)
	}
}

// emit_string writes s as a double-quoted Odin string literal.
emit_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

specs_use_time :: proc(specs: []Query_Spec) -> bool {
	for s in specs {
		for a in s.args {
			if a.type == "time.Time" {return true}
		}
		for r in s.results {
			if r.type == "time.Time" {return true}
		}
	}
	return false
}

// --- Shared helpers ---

is_ident :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c == '_':
		case c >= '0' && c <= '9' && i > 0:
		case:
			return false
		}
	}
	return true
}

is_supported_type :: proc(t: string) -> bool {
	switch t {
	case "i64", "i32", "i16", "i8", "int", "u64", "u32", "u16", "u8", "uint",
	     "f64", "f32", "bool", "string", "[]byte", "[]u8", "time.Time":
		return true
	}
	return false
}

// --- Driver (CLI) ---

// Driver_Kind selects which driver describes the queries (and the placeholder
// dialect). `-db` carries a file path for sqlite/duckdb and a DSN for postgres.
Driver_Kind :: enum {
	Sqlite,
	Postgres,
	Duckdb,
}

Options :: struct {
	sql_dir: string `args:"pos=0,required" usage:"directory of annotated .sql query files"`,
	out_dir: string `args:"pos=1,required" usage:"package directory to write queries.gen.odin into"`,
	db:      string `args:"name=db,required" usage:"a database already loaded with the schema, used to describe result columns (file path for sqlite/duckdb, DSN for postgres)"`,
	driver:  string `args:"name=driver" usage:"target driver: sqlite (default), postgres, or duckdb (build with -define:QUERYGEN_DUCKDB=true)"`,
	pkg:     string `args:"name=package" usage:"package name for the generated file (default: inferred from out-dir)"`,
}

// run parses args, generates the data-access procedures, and returns a process
// exit code. `prog` is the program name shown in usage.
run :: proc(prog: string, args: []string) -> int {
	opt: Options
	program_args := make([]string, len(args) + 1, context.temp_allocator)
	program_args[0] = prog
	copy(program_args[1:], args)
	flags.parse_or_exit(&opt, program_args, .Unix)

	kind: Driver_Kind
	switch opt.driver {
	case "", "sqlite":
		kind = .Sqlite
	case "postgres", "pg":
		kind = .Postgres
	case "duckdb", "duck":
		kind = .Duckdb
	case:
		fmt.eprintfln(
			"querygen: -driver must be 'sqlite', 'postgres', or 'duckdb', got %q",
			opt.driver,
		)
		return 2
	}
	style := kind == .Postgres ? Placeholder_Style.Dollar : Placeholder_Style.Question

	specs, lerr := load_dir(opt.sql_dir, style)
	if lerr != "" {
		fmt.eprintfln("querygen: %s", lerr)
		return 1
	}
	if len(specs) == 0 {
		fmt.printfln("querygen: no queries found in %s", opt.sql_dir)
		return 0
	}

	db: ^sql.DB
	oerr: sql.Error
	switch kind {
	case .Sqlite:
		db, oerr = sql.open(&sqlite.driver, opt.db)
	case .Postgres:
		db, oerr = sql.open(&postgres.driver, opt.db)
	case .Duckdb:
		when QUERYGEN_DUCKDB {
			db, oerr = sql.open(&duck.driver, opt.db)
		} else {
			fmt.eprintln(
				"querygen: DuckDB support isn't compiled in. Rebuild with -define:QUERYGEN_DUCKDB=true and set the libduckdb loader path.",
			)
			return 2
		}
	}
	if oerr != nil {
		fmt.eprintfln("querygen: open %s: %v", opt.db, oerr)
		return 1
	}
	defer sql.close(db)
	sql.set_max_open_conns(db, 1) // describe is serial; keeps a :memory: schema on one conn

	if derr := describe(db, specs[:]); derr != "" {
		fmt.eprintfln("querygen: %s", derr)
		return 1
	}

	pkg_name := opt.pkg
	if pkg_name == "" {
		pkg_name = infer_package_name(opt.out_dir)
	}

	src := emit(pkg_name, specs[:])
	out, _ := filepath.join({opt.out_dir, "queries.gen.odin"}, context.allocator)
	if werr := os.write_entire_file(out, transmute([]u8)src); werr != nil {
		fmt.eprintfln("querygen: write %s: %v", out, werr)
		return 1
	}
	fmt.printfln("querygen: wrote %s (%d quer(y/ies))", out, len(specs))
	return 0
}

// load_dir reads every `.sql` file in dir (sorted for determinism), parses each,
// and returns the combined specs. Returns ("" on success) or an error message
// prefixed with the offending file.
load_dir :: proc(
	dir: string,
	style := Placeholder_Style.Question,
	allocator := context.allocator,
) -> (
	specs: [dynamic]Query_Spec,
	err: string,
) {
	specs = make([dynamic]Query_Spec, allocator)

	infos, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {
		return specs, fmt.tprintf("read dir %q: %v", dir, derr)
	}

	names := make([dynamic]string, context.temp_allocator)
	paths := make(map[string]string, allocator = context.temp_allocator)
	for info in infos {
		if info.type == .Directory {continue}
		if !strings.has_suffix(info.name, ".sql") {continue}
		append(&names, info.name)
		paths[info.name] = info.fullpath
	}
	slice.sort(names[:])

	seen := make(map[string]bool, allocator = context.temp_allocator)
	for fname in names {
		data, rerr := os.read_entire_file_from_path(paths[fname], context.temp_allocator)
		if rerr != nil {
			return specs, fmt.tprintf("read %q: %v", fname, rerr)
		}
		file_specs, perr := parse_queries(string(data), style, allocator)
		if pe, ok := perr.?; ok {
			if pe.line > 0 {
				return specs, fmt.tprintf("%s:%d: %s", fname, pe.line, pe.msg)
			}
			return specs, fmt.tprintf("%s: %s", fname, pe.msg)
		}
		for s in file_specs {
			if seen[s.name] {
				return specs, fmt.tprintf("%s: duplicate query name %q", fname, s.name)
			}
			seen[s.name] = true
			append(&specs, s)
		}
	}
	return specs, ""
}

// infer_package_name reads the package declaration of any .odin file already in
// out_dir; failing that it falls back to the directory's basename.
infer_package_name :: proc(dir: string) -> string {
	if pkg, ok := parser.parse_package_from_path(dir); ok {
		for _, f in pkg.files {
			if f.pkg_decl != nil && f.pkg_decl.name != "" {
				return f.pkg_decl.name
			}
		}
	}
	return filepath.base(dir)
}

main :: proc() {
	os.exit(run(os.args[0], os.args[1:]))
}

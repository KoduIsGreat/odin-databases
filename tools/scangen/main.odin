// scangen — generate concrete row-mapper procs for structs annotated
// with `//+sql:scan` doc comments.
//
// Usage:
//   odin run tools/scangen -- <pkg-dir>
//
// For each annotated struct in <pkg-dir>, emits a `scan_<TypeName>` proc
// in <pkg-dir>/scan.gen.odin, plus a `scan_row :: proc{...}` overload set
// covering all annotated structs in the package.
//
// User code:
//
//   //+sql:scan
//   User :: struct {
//       id:   i64,
//       name: string,
//       age:  int,
//   }
//
// becomes generated code:
//
//   scan_User :: proc(rows: ^sql.Rows, dest: ^User) -> sql.Error { ... }
//   scan :: proc{
//       scan_User,                // codegen: concrete dispatch wins for ^User
//       sql.scan_struct,          // reflection fallback for any other ^$T
//       sql.scan_values,          // positional `scan(rows, &a, &b, ...)`
//       sql.row_scan_struct,      // ^Row variants for query_row
//       sql.row_scan_values,
//   }
//
// User code can then write `scan(&rows, &user)` regardless of whether the
// destination type is annotated — Odin's overload resolution picks the
// concrete generated proc when one exists, otherwise falls back to the
// reflective sql.scan_struct.
//
// Limitations (MVP):
//   - Field name must equal column name (no struct-tag renaming yet).
//   - Supported types: int family, f32/f64, bool, string, []byte, time.Time.
//   - One package dir per invocation; run again per package as needed.
package scangen

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:path/filepath"
import "core:os"
import "core:strings"

// --- Specs collected from the AST ---

Field_Spec :: struct {
	name:       string,
	odin_type:  string, // verbatim type text from the source
}

Struct_Spec :: struct {
	name:   string,
	fields: [dynamic]Field_Spec,
}

Pkg_Spec :: struct {
	pkg_name: string,
	dir:      string,
	structs:  [dynamic]Struct_Spec,
	uses_strings: bool, // emit `import "core:strings"` if any string/[]byte field
	uses_time:    bool, // emit `import "core:time"` if any time.Time field
}

// --- Type classification ---

Kind :: enum {
	Unsupported,
	Int_From_I64,   // any int-family type, source value is i64
	Float_From_F64, // f32/f64, source value is f64
	Bool,
	String,
	Bytes,
	Time,
}

classify :: proc(t: string) -> Kind {
	switch t {
	case "i64", "i32", "i16", "i8", "int":
		return .Int_From_I64
	case "u64", "u32", "u16", "u8", "uint":
		return .Int_From_I64
	case "f64", "f32":
		return .Float_From_F64
	case "bool":
		return .Bool
	case "string":
		return .String
	case "[]byte", "[]u8":
		return .Bytes
	case "time.Time":
		return .Time
	}
	return .Unsupported
}

// --- AST walking ---

ANNOTATION :: "+sql:scan"

has_scan_annotation :: proc(docs: ^ast.Comment_Group) -> bool {
	if docs == nil {return false}
	for tok in docs.list {
		// tok.text is the full comment including leading "//".
		if strings.contains(tok.text, ANNOTATION) {return true}
	}
	return false
}

source_of :: proc(file: ^ast.File, node: ^ast.Node) -> string {
	return file.src[node.pos.offset:node.end.offset]
}

// unwrap_maybe turns "Maybe(X)" into "X" (trimmed), leaving other types as-is.
unwrap_maybe :: proc(t: string) -> string {
	if strings.has_prefix(t, "Maybe(") && strings.has_suffix(t, ")") {
		return strings.trim_space(t[len("Maybe("):len(t) - 1])
	}
	return t
}

collect_struct :: proc(
	pkg: ^Pkg_Spec,
	file: ^ast.File,
	name: string,
	st: ^ast.Struct_Type,
) {
	spec := Struct_Spec{name = name}

	if st.fields != nil {
		for f in st.fields.list {
			if f.type == nil {continue}
			// Unwrap Maybe(X) → X: the generated `dest.field = <X-typed>`
			// assignment converts implicitly into the Maybe field, and a NULL
			// (no case matched) leaves it at its zero value, None.
			type_text := unwrap_maybe(strings.trim_space(source_of(file, f.type)))
			for n in f.names {
				ident, ok := n.derived.(^ast.Ident)
				if !ok {continue}
				append(&spec.fields, Field_Spec{name = ident.name, odin_type = type_text})

				switch classify(type_text) {
				case .String, .Bytes:
					pkg.uses_strings = true
				case .Time:
					pkg.uses_time = true
				case .Unsupported, .Int_From_I64, .Float_From_F64, .Bool:
				}
			}
		}
	}

	append(&pkg.structs, spec)
}

walk_file :: proc(pkg: ^Pkg_Spec, file: ^ast.File) {
	if pkg.pkg_name == "" && file.pkg_decl != nil {
		pkg.pkg_name = file.pkg_decl.name
	}

	for decl in file.decls {
		vd, ok := decl.derived.(^ast.Value_Decl)
		if !ok {continue}
		if !has_scan_annotation(vd.docs) {continue}
		if len(vd.names) != 1 || len(vd.values) != 1 {continue}

		ident, _ := vd.names[0].derived.(^ast.Ident)
		if ident == nil {continue}

		// `Foo :: struct { ... }`  → values[0] is a Struct_Type
		st, st_ok := vd.values[0].derived.(^ast.Struct_Type)
		if !st_ok {continue}

		collect_struct(pkg, file, ident.name, st)
	}
}

// --- Emission ---

emit :: proc(pkg: ^Pkg_Spec) -> string {
	b := strings.builder_make()
	w := strings.write_string

	w(&b, "// Code generated by tools/scangen. DO NOT EDIT.\n")
	w(&b, "package ")
	w(&b, pkg.pkg_name)
	w(&b, "\n\n")

	if pkg.uses_strings {w(&b, "import \"core:strings\"\n")}
	if pkg.uses_time {w(&b, "import \"core:time\"\n")}
	w(&b, "import sql \"database:sql\"\n\n")

	for i in 0 ..< len(pkg.structs) {
		emit_struct_proc(&b, &pkg.structs[i])
		w(&b, "\n")
	}

	// Unified overload set: generated concrete procs first, then the four
	// public sql procs as the reflective fallback.
	if len(pkg.structs) > 0 {
		w(&b, "scan :: proc{\n")
		for spec in pkg.structs {
			w(&b, "\tscan_")
			w(&b, spec.name)
			w(&b, ",\n")
		}
		w(&b, "\tsql.scan_struct,\n")
		w(&b, "\tsql.scan_values,\n")
		w(&b, "\tsql.row_scan_struct,\n")
		w(&b, "\tsql.row_scan_values,\n")
		w(&b, "}\n")
	}

	return strings.to_string(b)
}

// Helpers — explicit string concatenation rather than fmt.sbprintf so we
// don't have to brace-escape generated `{` / `}` in our output strings.
@(private="file")
ws :: proc(b: ^strings.Builder, parts: ..string) {
	for p in parts {strings.write_string(b, p)}
}

emit_struct_proc :: proc(b: ^strings.Builder, spec: ^Struct_Spec) {
	ws(b, "scan_", spec.name, " :: proc(rows: ^sql.Rows, dest: ^", spec.name, ") -> sql.Error {\n")
	ws(b, "\tif !rows.has_row {\n")
	ws(b, "\t\treturn sql.Scan_Error{kind = .No_Row, col_idx = -1}\n")
	ws(b, "\t}\n")
	ws(b, "\tdetached := sql.row_detached(rows)\n")
	ws(b, "\t_ = detached\n") // suppress "declared but not used" if no string/bytes fields
	ws(b, "\tfor ci in 0 ..< rows.col_count {\n")
	ws(b, "\t\tname := sql.row_col_name(rows, ci)\n")
	ws(b, "\t\tval  := sql.row_value(rows, ci)\n")
	ws(b, "\t\t_ = val\n")
	ws(b, "\t\tswitch name {\n")
	for i in 0 ..< len(spec.fields) {
		emit_field_case(b, &spec.fields[i])
	}
	ws(b, "\t\t}\n")
	ws(b, "\t}\n")
	ws(b, "\treturn nil\n")
	ws(b, "}\n")
}

emit_field_case :: proc(b: ^strings.Builder, f: ^Field_Spec) {
	ws(b, "\t\tcase \"", f.name, "\":\n")
	switch classify(f.odin_type) {
	case .Int_From_I64:
		ws(b, "\t\t\tif v, ok := val.(i64); ok { dest.", f.name, " = ", f.odin_type, "(v) }\n")
	case .Float_From_F64:
		// Accept an i64 source too: SQLite NUMERIC/DECIMAL columns store
		// integral values as INTEGER, which the driver reads back as i64.
		conv := "v" if f.odin_type == "f64" else "f32(v)"
		iconv := "f64(v)" if f.odin_type == "f64" else "f32(v)"
		ws(b, "\t\t\t#partial switch v in val {\n")
		ws(b, "\t\t\tcase f64: dest.", f.name, " = ", conv, "\n")
		ws(b, "\t\t\tcase i64: dest.", f.name, " = ", iconv, "\n")
		ws(b, "\t\t\t}\n")
	case .Bool:
		ws(b, "\t\t\t#partial switch x in val {\n")
		ws(b, "\t\t\tcase bool: dest.", f.name, " = x\n")
		ws(b, "\t\t\tcase i64:  dest.", f.name, " = x != 0\n")
		ws(b, "\t\t\t}\n")
	case .String:
		ws(b, "\t\t\tif v, ok := val.(string); ok {\n")
		ws(b, "\t\t\t\tdest.", f.name, " = v if detached else strings.clone(v)\n")
		ws(b, "\t\t\t}\n")
	case .Bytes:
		ws(b, "\t\t\tif v, ok := val.([]byte); ok {\n")
		ws(b, "\t\t\t\tif detached {\n")
		ws(b, "\t\t\t\t\tdest.", f.name, " = v\n")
		ws(b, "\t\t\t\t} else {\n")
		ws(b, "\t\t\t\t\tcp := make([]byte, len(v)); copy(cp, v); dest.", f.name, " = cp\n")
		ws(b, "\t\t\t\t}\n")
		ws(b, "\t\t\t}\n")
	case .Time:
		ws(b, "\t\t\tif v, ok := val.(time.Time); ok { dest.", f.name, " = v }\n")
	case .Unsupported:
		ws(b, "\t\t\t// scangen: unsupported field type \"", f.odin_type, "\" for ", f.name, "; skipping\n")
	}
}

// --- Driver ---

// Options is the scangen command line, parsed declaratively by core:flags.
Options :: struct {
	dir: string `args:"pos=0,required" usage:"package directory to scan for //+sql:scan structs (writes <dir>/scan.gen.odin)"`,
}

// run parses args and generates the scanners, returning a process exit code.
// `prog` is the program name shown in usage ("scangen" standalone, "odb scan"
// under the unified CLI). Exposed so the `odb` dispatcher can call it.
run :: proc(prog: string, args: []string) -> int {
	opt: Options
	program_args := make([]string, len(args) + 1, context.temp_allocator)
	program_args[0] = prog
	copy(program_args[1:], args)
	flags.parse_or_exit(&opt, program_args) // handles -h / usage / errors

	pkg, ok := parser.parse_package_from_path(opt.dir)
	if !ok {
		fmt.eprintfln("scangen: failed to parse package at %s", opt.dir)
		return 1
	}

	spec := Pkg_Spec{dir = opt.dir}
	for _, file in pkg.files {
		walk_file(&spec, file)
	}

	out, _ := filepath.join({opt.dir, "scan.gen.odin"}, context.allocator)
	if len(spec.structs) == 0 {
		fmt.printfln("scangen: no `%s` annotations found in %s", ANNOTATION, opt.dir)
		os.remove(out) // drop any stale generated file
		return 0
	}

	src := emit(&spec)
	if werr := os.write_entire_file(out, transmute([]u8)src); werr != nil {
		fmt.eprintfln("scangen: write %s: %v", out, werr)
		return 1
	}

	fmt.printfln("scangen: wrote %s (%d struct(s))", out, len(spec.structs))
	return 0
}

main :: proc() {
	os.exit(run(os.args[0], os.args[1:]))
}

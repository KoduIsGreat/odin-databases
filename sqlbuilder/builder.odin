// sqlbuilder — a SQL builder with two layers.
//
// Typed layer (preferred)
//
// The typed layer is driven by *column descriptors* — `Column(T)` values
// that pair a column's table/name with the Odin type `T` it maps to. These
// descriptors are normally produced by `tools/schemagen` into a
// `schema.gen.odin` file, one descriptor object per table:
//
//   Users := struct {
//       _info: sqlbuilder.Table_Info,
//       id:    sqlbuilder.Column(i64),
//       name:  sqlbuilder.Column(string),
//       age:   sqlbuilder.Column(int),
//   }{ ... }
//
// You then build queries against the generated identifiers, so a mistyped
// column name is a compile error, and predicate constructors enforce that
// the value matches the column's type:
//
//   b: Builder; init(&b); defer destroy(&b)
//   select(&b, Users.id, Users.name)             // unknown column → won't compile
//   from(&b, Users)
//   where_(&b, ge(Users.age, 18))                // ge(Column($T), T) → "x" won't compile
//   q, args := to_query(&b)
//
// Predicate constructors allocate their fragment + args with
// `context.temp_allocator` by default; `where()`/`set()` copy what they need
// into the builder's own buffer/args, so predicates need not outlive the
// call. Pass an explicit allocator to override.
//
// Raw layer (escape hatch)
//
// The `raw_*` procedures and the low-level `write`/`param` are an honest
// *string builder*: they append clauses in call order and assume the caller
// knows SQL. They do NOT escape identifiers — DO NOT pass untrusted input;
// use `ident()` to validate caller-supplied names. They exist for SQL the
// typed layer can't yet express (e.g. aggregate functions, table aliases,
// dialect-specific syntax).
//
// Values
//
// Anything that should be a SQL parameter goes through a predicate, `set()`,
// `param()`, `values()`, or the `raw_*` arg-bearing procs — these append `?`
// placeholders and record the value in the `args` slice returned by
// `to_query()`.
package sqlbuilder

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

import sql "database:sql"

Value :: sql.Value

Builder :: struct {
	buf:         strings.Builder,
	args:        [dynamic]Value,
	where_count: int,
	set_count:   int,
	join_count:  int,
}

// --- Descriptor types (typed layer) ---

// Column_Base is the type-erased column descriptor: its table-qualified
// identity, the Odin type it maps to, and whether the column is nullable.
// `select`/`order_by` and other column-list contexts take `Column_Base` so
// columns of different types can share one list — a `Column(T)` converts to
// `Column_Base` implicitly (via its embedded base), so pass `SomeColumn`.
Column_Base :: struct {
	table:    string,
	name:     string,
	type_id:  typeid,
	nullable: bool,
}

// Column(T) is a column descriptor carrying its mapped Odin type `T` in the
// type system, so predicate constructors like `eq`/`ge` can require the
// compared value to be a `T`. Embeds `Column_Base` via `using`, so `.table`,
// `.name`, `.type_id`, and `.base` are all available.
Column :: struct($T: typeid) {
	using base: Column_Base,
}

// Table_Info names a table for `from`/`update`/`delete_from`/`insert_into`.
Table_Info :: struct {
	name: string,
}

// Predicate is a rendered boolean SQL fragment plus its parameter values.
// Build them with eq/ne/lt/le/gt/ge/like/is_null/is_not_null and compose
// with and_/or_/not_.
Predicate :: struct {
	sql:  string,
	args: []Value,
}

// Ordering pairs a column with a sort direction for `order_by`.
Ordering :: struct {
	col:  Column_Base,
	desc: bool,
}

// Join_Kind selects the join keyword written before the table. Right/Full
// require SQLite 3.39+. Cross takes no ON clause.
Join_Kind :: enum {
	Inner,
	Left,
	Right,
	Full,
	Cross,
}

// Binding pairs a column name with a value for a typed INSERT. Build it with
// `bind`, which type-checks the value against the column.
Binding :: struct {
	col: string,
	val: Value,
}

// --- Lifecycle procs ---

init :: proc(b: ^Builder, allocator := context.allocator) {
	strings.builder_init(&b.buf, allocator)
	b.args = make([dynamic]Value, allocator)
	b.where_count = 0
	b.set_count = 0
	b.join_count = 0
}

destroy :: proc(b: ^Builder) {
	strings.builder_destroy(&b.buf)
	delete(b.args)
}

reset :: proc(b: ^Builder) {
	strings.builder_reset(&b.buf)
	clear(&b.args)
	b.where_count = 0
	b.set_count = 0
	b.join_count = 0
}

// --- Low-level procs ---

write :: proc(b: ^Builder, sql_str: string) {
	strings.write_string(&b.buf, sql_str)
}

param :: proc(b: ^Builder, val: Value) {
	strings.write_string(&b.buf, "?")
	append(&b.args, val)
}

// ident returns true if name is a plain SQL identifier safe to write
// verbatim into a query — letters, digits, underscore, optionally one
// `.` for table-qualified columns. Use it to guard caller-supplied
// column / table names before passing them to the raw_* procs.
ident :: proc(name: string) -> bool {
	if len(name) == 0 {return false}
	dots := 0
	for i in 0 ..< len(name) {
		ch := name[i]
		switch {
		case ch >= 'a' && ch <= 'z':
		case ch >= 'A' && ch <= 'Z':
		case ch == '_':
		case (ch >= '0' && ch <= '9') && i > 0:
		case ch == '.':
			dots += 1
			if dots > 1 || i == 0 || i == len(name) - 1 {return false}
		case:
			return false
		}
	}
	return true
}

// to_value converts a column-typed Odin value into the driver `Value` union,
// coercing int-family → i64 and f32 → f64 to match the supported variants.
// It is the bridge used by predicate constructors and `set`.
to_value :: proc(v: $T) -> Value {
	when T == bool {
		return v
	} else when T == string {
		return v
	} else when T == f64 {
		return v
	} else when T == f32 {
		return f64(v)
	} else when T == time.Time {
		return v
	} else when T == []byte {
		return v
	} else when intrinsics.type_is_integer(T) {
		return i64(v)
	} else {
		#panic("sqlbuilder: unsupported column value type for to_value")
	}
}

// --- Predicate constructors ---

@(private)
_cmp :: proc(c: Column_Base, op: string, v: Value, allocator: runtime.Allocator) -> Predicate {
	sql_str := fmt.aprintf("%s.%s %s ?", c.table, c.name, op, allocator = allocator)
	args := make([]Value, 1, allocator)
	args[0] = v
	return Predicate{sql = sql_str, args = args}
}

eq :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, "=", to_value(v), allocator)
}
ne :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, "!=", to_value(v), allocator)
}
lt :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, "<", to_value(v), allocator)
}
le :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, "<=", to_value(v), allocator)
}
gt :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, ">", to_value(v), allocator)
}
ge :: proc(c: Column($T), v: T, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, ">=", to_value(v), allocator)
}

like :: proc(c: Column(string), pattern: string, allocator := context.temp_allocator) -> Predicate {
	return _cmp(c.base, "LIKE", pattern, allocator)
}

is_null :: proc(c: Column($T), allocator := context.temp_allocator) -> Predicate {
	sql_str := fmt.aprintf("%s.%s IS NULL", c.base.table, c.base.name, allocator = allocator)
	return Predicate{sql = sql_str, args = {}}
}

is_not_null :: proc(c: Column($T), allocator := context.temp_allocator) -> Predicate {
	sql_str := fmt.aprintf("%s.%s IS NOT NULL", c.base.table, c.base.name, allocator = allocator)
	return Predicate{sql = sql_str, args = {}}
}

// Column-to-column predicates compare two columns rather than a column and a
// value — the typical building block of a JOIN ... ON clause. Both columns
// must map to the same Odin type `T`, so you can't join an i64 column against
// a string one. They take no parameters (nothing appended to args).

@(private)
_col_cmp :: proc(a: Column_Base, op: string, c: Column_Base, allocator: runtime.Allocator) -> Predicate {
	sql_str := fmt.aprintf("%s.%s %s %s.%s", a.table, a.name, op, c.table, c.name, allocator = allocator)
	return Predicate{sql = sql_str, args = {}}
}

col_eq :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, "=", c.base, allocator)
}
col_ne :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, "!=", c.base, allocator)
}
col_lt :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, "<", c.base, allocator)
}
col_le :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, "<=", c.base, allocator)
}
col_gt :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, ">", c.base, allocator)
}
col_ge :: proc(a: Column($T), c: Column(T), allocator := context.temp_allocator) -> Predicate {
	return _col_cmp(a.base, ">=", c.base, allocator)
}

@(private)
_combine :: proc(op: string, preds: []Predicate, allocator: runtime.Allocator) -> Predicate {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	strings.write_byte(&sb, '(')
	total := 0
	for p, i in preds {
		if i > 0 {strings.write_string(&sb, op)}
		strings.write_string(&sb, p.sql)
		total += len(p.args)
	}
	strings.write_byte(&sb, ')')

	args := make([]Value, total, allocator)
	idx := 0
	for p in preds {
		for a in p.args {
			args[idx] = a
			idx += 1
		}
	}
	return Predicate{sql = strings.to_string(sb), args = args}
}

and_ :: proc(preds: ..Predicate, allocator := context.temp_allocator) -> Predicate {
	return _combine(" AND ", preds, allocator)
}
or_ :: proc(preds: ..Predicate, allocator := context.temp_allocator) -> Predicate {
	return _combine(" OR ", preds, allocator)
}
not_ :: proc(p: Predicate, allocator := context.temp_allocator) -> Predicate {
	sql_str := fmt.aprintf("NOT (%s)", p.sql, allocator = allocator)
	args := make([]Value, len(p.args), allocator)
	copy(args, p.args)
	return Predicate{sql = sql_str, args = args}
}

// asc/desc wrap a typed column as an Ordering for `order_by`.
asc :: proc(c: Column($T)) -> Ordering {
	return Ordering{col = c.base, desc = false}
}
desc :: proc(c: Column($T)) -> Ordering {
	return Ordering{col = c.base, desc = true}
}

// --- Typed query procs ---

@(private)
_write_qualified :: proc(b: ^Builder, c: Column_Base) {
	strings.write_string(&b.buf, c.table)
	strings.write_byte(&b.buf, '.')
	strings.write_string(&b.buf, c.name)
}

// _table_name pulls the SQL table name out of a generated descriptor object
// (the `X := struct { _info: Table_Info, ... }` schemagen emits). Taking the
// descriptor generically lets callers pass `Users` rather than `Users._info`;
// a value without an `_info: Table_Info` field is a compile error.
@(private)
_table_name :: proc(table: $T) -> string {
	return table._info.name
}

select :: proc(b: ^Builder, cols: ..Column_Base) {
	if len(cols) == 0 {
		strings.write_string(&b.buf, "SELECT *")
	} else {
		strings.write_string(&b.buf, "SELECT ")
		for c, i in cols {
			if i > 0 {strings.write_string(&b.buf, ", ")}
			_write_qualified(b, c)
		}
	}
}

from :: proc(b: ^Builder, table: $T) {
	strings.write_string(&b.buf, " FROM ")
	strings.write_string(&b.buf, _table_name(table))
}

@(private)
_join_keyword :: proc(k: Join_Kind) -> string {
	switch k {
	case .Inner:
		return "JOIN"
	case .Left:
		return "LEFT JOIN"
	case .Right:
		return "RIGHT JOIN"
	case .Full:
		return "FULL JOIN"
	case .Cross:
		return "CROSS JOIN"
	}
	return "JOIN"
}

// join writes ` <kind> <table> ON <on>`, recording the predicate's args.
// Build `on` from col_eq/col_ne/... (composed with and_/or_ for multi-column
// conditions). For a Cross join the `on` predicate is ignored.
join :: proc(b: ^Builder, table: $T, on: Predicate, kind := Join_Kind.Inner) {
	strings.write_byte(&b.buf, ' ')
	strings.write_string(&b.buf, _join_keyword(kind))
	strings.write_byte(&b.buf, ' ')
	strings.write_string(&b.buf, _table_name(table))
	if kind != .Cross {
		strings.write_string(&b.buf, " ON ")
		strings.write_string(&b.buf, on.sql)
		for a in on.args {
			append(&b.args, a)
		}
	}
	b.join_count += 1
}

where_ :: proc(b: ^Builder, p: Predicate) {
	if b.where_count == 0 {
		strings.write_string(&b.buf, " WHERE ")
	} else {
		strings.write_string(&b.buf, " AND ")
	}
	strings.write_string(&b.buf, p.sql)
	b.where_count += 1
	for a in p.args {
		append(&b.args, a)
	}
}

order_by :: proc(b: ^Builder, orderings: ..Ordering) {
	strings.write_string(&b.buf, " ORDER BY ")
	for o, i in orderings {
		if i > 0 {strings.write_string(&b.buf, ", ")}
		_write_qualified(b, o.col)
		if o.desc {strings.write_string(&b.buf, " DESC")}
	}
}

limit :: proc(b: ^Builder, n: int) {
	strings.write_string(&b.buf, " LIMIT ")
	_write_int(&b.buf, n)
}

offset :: proc(b: ^Builder, n: int) {
	strings.write_string(&b.buf, " OFFSET ")
	_write_int(&b.buf, n)
}

// --- Typed mutation procs ---

// bind pairs a column with a value for a typed INSERT, checking the value
// against the column's type — a wrong-typed value won't compile. Pass the
// results to `insert_into`.
bind :: proc(c: Column($T), v: T) -> Binding {
	return Binding{col = c.name, val = to_value(v)}
}

// insert_into writes a complete `INSERT INTO t (cols) VALUES (?, ...)` from
// typed column/value bindings, recording one arg per binding. With no
// bindings it writes `INSERT INTO t DEFAULT VALUES`.
insert_into :: proc(b: ^Builder, table: $T, bindings: ..Binding) {
	strings.write_string(&b.buf, "INSERT INTO ")
	strings.write_string(&b.buf, _table_name(table))
	if len(bindings) == 0 {
		strings.write_string(&b.buf, " DEFAULT VALUES")
		return
	}
	strings.write_string(&b.buf, " (")
	for bnd, i in bindings {
		if i > 0 {strings.write_string(&b.buf, ", ")}
		strings.write_string(&b.buf, bnd.col) // column list is unqualified
	}
	strings.write_string(&b.buf, ") VALUES (")
	for bnd, i in bindings {
		if i > 0 {strings.write_string(&b.buf, ", ")}
		strings.write_string(&b.buf, "?")
		append(&b.args, bnd.val)
	}
	strings.write_string(&b.buf, ")")
}

update :: proc(b: ^Builder, table: $T) {
	strings.write_string(&b.buf, "UPDATE ")
	strings.write_string(&b.buf, _table_name(table))
}

// set appends `col = ?` to the SET list (comma-joining successive calls),
// recording the value. The value must match the column's type.
set :: proc(b: ^Builder, c: Column($T), v: T) {
	if b.set_count == 0 {
		strings.write_string(&b.buf, " SET ")
	} else {
		strings.write_string(&b.buf, ", ")
	}
	strings.write_string(&b.buf, c.name) // SET column is unqualified
	strings.write_string(&b.buf, " = ?")
	b.set_count += 1
	append(&b.args, to_value(v))
}

delete_from :: proc(b: ^Builder, table: $T) {
	strings.write_string(&b.buf, "DELETE FROM ")
	strings.write_string(&b.buf, _table_name(table))
}

// --- Raw layer (string escape hatch) ---

raw_select :: proc(b: ^Builder, cols: ..string) {
	if len(cols) == 0 {
		strings.write_string(&b.buf, "SELECT *")
	} else {
		strings.write_string(&b.buf, "SELECT ")
		for col, i in cols {
			if i > 0 {strings.write_string(&b.buf, ", ")}
			strings.write_string(&b.buf, col)
		}
	}
}

raw_from :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, " FROM ")
	strings.write_string(&b.buf, table)
}

raw_where :: proc(b: ^Builder, clause: string, args: ..Value) {
	if b.where_count == 0 {
		strings.write_string(&b.buf, " WHERE ")
	} else {
		strings.write_string(&b.buf, " AND ")
	}
	strings.write_string(&b.buf, clause)
	b.where_count += 1
	for arg in args {
		append(&b.args, arg)
	}
}

// raw_join writes ` JOIN <table> ON <clause>`, recording any args.
// Subsequent calls write additional JOIN clauses (not chained ANDs).
raw_join :: proc(b: ^Builder, table: string, clause: string, args: ..Value) {
	strings.write_string(&b.buf, " JOIN ")
	strings.write_string(&b.buf, table)
	strings.write_string(&b.buf, " ON ")
	strings.write_string(&b.buf, clause)
	b.join_count += 1
	for arg in args {
		append(&b.args, arg)
	}
}

raw_order_by :: proc(b: ^Builder, cols: ..string) {
	strings.write_string(&b.buf, " ORDER BY ")
	for col, i in cols {
		if i > 0 {strings.write_string(&b.buf, ", ")}
		strings.write_string(&b.buf, col)
	}
}

raw_insert_into :: proc(b: ^Builder, table: string, cols: ..string) {
	strings.write_string(&b.buf, "INSERT INTO ")
	strings.write_string(&b.buf, table)
	if len(cols) > 0 {
		strings.write_string(&b.buf, " (")
		for col, i in cols {
			if i > 0 {strings.write_string(&b.buf, ", ")}
			strings.write_string(&b.buf, col)
		}
		strings.write_string(&b.buf, ")")
	}
}

// values appends ` VALUES (?, ?, ...)`, recording one arg per value. Pairs
// with raw_insert_into; positional and not type-checked. The typed
// insert_into uses bind() instead.
values :: proc(b: ^Builder, args: ..Value) {
	strings.write_string(&b.buf, " VALUES (")
	for arg, i in args {
		if i > 0 {strings.write_string(&b.buf, ", ")}
		strings.write_string(&b.buf, "?")
		append(&b.args, arg)
	}
	strings.write_string(&b.buf, ")")
}

raw_update :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, "UPDATE ")
	strings.write_string(&b.buf, table)
}

raw_set :: proc(b: ^Builder, clause: string, args: ..Value) {
	if b.set_count == 0 {
		strings.write_string(&b.buf, " SET ")
	} else {
		strings.write_string(&b.buf, ", ")
	}
	strings.write_string(&b.buf, clause)
	b.set_count += 1
	for arg in args {
		append(&b.args, arg)
	}
}

raw_delete_from :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, "DELETE FROM ")
	strings.write_string(&b.buf, table)
}

// --- Output ---

to_query :: proc(b: ^Builder) -> (string, []Value) {
	return strings.to_string(b.buf), b.args[:]
}

// --- Internal helpers ---

@(private)
_write_int :: proc(buf: ^strings.Builder, n: int) {
	if n < 0 {
		strings.write_byte(buf, '-')
		_write_uint(buf, uint(-n))
	} else {
		_write_uint(buf, uint(n))
	}
}

@(private)
_write_uint :: proc(buf: ^strings.Builder, n: uint) {
	if n >= 10 {
		_write_uint(buf, n / 10)
	}
	strings.write_byte(buf, byte('0' + n % 10))
}

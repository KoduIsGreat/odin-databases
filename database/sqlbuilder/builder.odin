package sqlbuilder

import "core:strings"

import sql "../../database/sql"

Value :: sql.Value

Builder :: struct {
	buf:         strings.Builder,
	args:        [dynamic]Value,
	where_count: int,
	set_count:   int,
	join_count:  int,
}

// Lifecycle procs

init :: proc(b: ^Builder, allocator := context.allocator) {
	strings.builder_init(&b.buf, allocator)
	b.args = make([dynamic]Value, allocator)
	b.where_count = 0
	b.set_count = 0
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
}

// Low-level procs

write :: proc(b: ^Builder, sql_str: string) {
	strings.write_string(&b.buf, sql_str)
}

param :: proc(b: ^Builder, val: Value) {
	strings.write_string(&b.buf, "?")
	append(&b.args, val)
}

// SELECT query procs

select :: proc(b: ^Builder, cols: ..string) {
	if len(cols) == 0 {
		strings.write_string(&b.buf, "SELECT *")
	} else {
		strings.write_string(&b.buf, "SELECT ")
		for col, i in cols {
			if i > 0 {
				strings.write_string(&b.buf, ", ")
			}
			strings.write_string(&b.buf, col)
		}
	}
}

from :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, " FROM ")
	strings.write_string(&b.buf, table)
}

where_clause :: proc(b: ^Builder, clause: string, args: ..Value) {
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
join :: proc(b: ^Builder, table: string, clause: string, args: ..Value) {
	if b.join_count == 0 {
		strings.write_string(&b.buf, " JOIN ")
	} else {
		strings.write_string(&b.buf, " AND ")
	}
	strings.write_string(&b.buf, " JOIN ")
	strings.write_string(&b.buf, table)
	strings.write_string(&b.buf, " ON ")
	strings.write_string(&b.buf, clause)
	b.join_count += 1
	for arg in args {
		append(&b.args, arg)
	}
}


order_by :: proc(b: ^Builder, cols: ..string) {
	strings.write_string(&b.buf, " ORDER BY ")
	for col, i in cols {
		if i > 0 {
			strings.write_string(&b.buf, ", ")
		}
		strings.write_string(&b.buf, col)
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

// Mutation procs

insert_into :: proc(b: ^Builder, table: string, cols: ..string) {
	strings.write_string(&b.buf, "INSERT INTO ")
	strings.write_string(&b.buf, table)
	if len(cols) > 0 {
		strings.write_string(&b.buf, " (")
		for col, i in cols {
			if i > 0 {
				strings.write_string(&b.buf, ", ")
			}
			strings.write_string(&b.buf, col)
		}
		strings.write_string(&b.buf, ")")
	}
}

values :: proc(b: ^Builder, args: ..Value) {
	strings.write_string(&b.buf, " VALUES (")
	for arg, i in args {
		if i > 0 {
			strings.write_string(&b.buf, ", ")
		}
		strings.write_string(&b.buf, "?")
		append(&b.args, arg)
	}
	strings.write_string(&b.buf, ")")
}

update :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, "UPDATE ")
	strings.write_string(&b.buf, table)
}

set_cols :: proc(b: ^Builder, clause: string, args: ..Value) {
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

delete_from :: proc(b: ^Builder, table: string) {
	strings.write_string(&b.buf, "DELETE FROM ")
	strings.write_string(&b.buf, table)
}

// Output

to_query :: proc(b: ^Builder) -> (string, []Value) {
	return strings.to_string(b.buf), b.args[:]
}

// Internal helpers

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

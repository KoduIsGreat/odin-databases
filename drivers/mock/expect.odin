package sqlmock

import "core:fmt"
import "core:strings"

import drv "database:driver"

// --- Expectation builders ----------------------------------------------------
//
// Each `expect_*` proc enqueues an Expectation and returns a pointer so the
// caller can attach a result, rows, or an injected error.

expect_exec :: proc(m: ^Mock, sql_match: string = "") -> ^Expectation {
	return enqueue(m, .Exec, sql_match)
}

expect_query :: proc(m: ^Mock, sql_match: string = "") -> ^Expectation {
	return enqueue(m, .Query, sql_match)
}

expect_prepare :: proc(m: ^Mock, sql_match: string = "") -> ^Expectation {
	return enqueue(m, .Prepare, sql_match)
}

expect_stmt_exec :: proc(m: ^Mock, sql_match: string = "") -> ^Expectation {
	return enqueue(m, .Stmt_Exec, sql_match)
}

expect_stmt_query :: proc(m: ^Mock, sql_match: string = "") -> ^Expectation {
	return enqueue(m, .Stmt_Query, sql_match)
}

expect_begin :: proc(m: ^Mock) -> ^Expectation {
	return enqueue(m, .Begin, "")
}

expect_commit :: proc(m: ^Mock) -> ^Expectation {
	return enqueue(m, .Commit, "")
}

expect_rollback :: proc(m: ^Mock) -> ^Expectation {
	return enqueue(m, .Rollback, "")
}

@(private)
enqueue :: proc(m: ^Mock, kind: Expectation_Kind, sql_match: string) -> ^Expectation {
	e := new(Expectation, m.allocator)
	e.mock = m
	e.kind = kind
	e.sql_match = sql_match
	append(&m.expectations, e)
	return e
}

// --- Result / row builders ---------------------------------------------------

returns_result :: proc(e: ^Expectation, last_insert_id: i64 = 0, rows_affected: i64 = 0) -> ^Expectation {
	e.result = drv.Result{last_insert_id = last_insert_id, rows_affected = rows_affected}
	return e
}

// returns_rows configures a Query/Stmt_Query expectation with the columns
// and row values to deliver. Everything is deep-copied into the mock's
// allocator (the same one that frees it in close()) — including string and
// []byte payloads — so the caller can pass literals or dynamically-built,
// stack-local data freely; nothing aliases caller memory after this returns.
//
// Panics if any row's value count doesn't match the column count — that
// is a fixture mistake worth surfacing immediately rather than at row-read
// time deep inside the driver.
returns_rows :: proc(e: ^Expectation, columns: []string, rows: [][]drv.Value) -> ^Expectation {
	for row, i in rows {
		if len(row) != len(columns) {
			panic_with_msg(e.mock,
				"sqlmock: row %d has %d value(s) but %d column(s) declared",
				i, len(row), len(columns))
		}
	}
	alloc := e.mock.allocator
	cols_copy := make([]string, len(columns), alloc)
	for c, i in columns {
		cols_copy[i] = strings.clone(c, alloc)
	}
	rows_copy := make([][]drv.Value, len(rows), alloc)
	for row, i in rows {
		dst := make([]drv.Value, len(row), alloc)
		for v, j in row {
			dst[j] = clone_value(v, alloc)
		}
		rows_copy[i] = dst
	}
	e.columns = cols_copy
	e.rows    = rows_copy
	return e
}

returns_error :: proc(e: ^Expectation, err: drv.Error) -> ^Expectation {
	e.error = err
	return e
}

// with_args attaches an args predicate. The predicate runs after the SQL
// match passes; returning false fails the call.
with_args :: proc(e: ^Expectation, pred: Args_Predicate) -> ^Expectation {
	e.args_check = pred
	return e
}

// --- Verification ------------------------------------------------------------

// assert_done returns (true, "") if every expectation has been consumed
// exactly once. Otherwise (false, message) describing what's missing.
// The returned message is owned by the mock and freed in `close`.
assert_done :: proc(mock: ^Mock) -> (bool, string) {
	leftover := 0
	for e in mock.expectations {
		if !e.consumed {leftover += 1}
	}
	if leftover == 0 {return true, ""}

	b: strings.Builder
	strings.builder_init(&b, mock.allocator)
	fmt.sbprintf(&b, "sqlmock: %d expectation(s) not consumed:", leftover)
	for e, i in mock.expectations {
		if e.consumed {continue}
		fmt.sbprintf(&b, "\n  [%d] %v sql=%q", i, e.kind, e.sql_match)
	}
	msg := strings.to_string(b)
	append(&mock.error_msgs, msg)
	return false, msg
}

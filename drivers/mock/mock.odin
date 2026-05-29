// database:drivers/mock — an expectation-based mock driver for testing code that uses
// `database:sql`. Modeled after Go's go-sqlmock.
//
// Usage (pass `t` so close() auto-asserts all expectations were consumed):
//   mock, db := sqlmock.open(t)
//   defer sqlmock.close(mock, db)
//
//   // type-safe fixtures from row structs (or use returns_rows for raw control):
//   sqlmock.returns_structs(
//       sqlmock.expect_query(mock, "SELECT id, name FROM users"),
//       []User{{id = 1, name = "alice"}, {id = 2, name = "bob"}},
//   )
//
//   // run code under test... close() then verifies every expectation was used.
//
// Expectations are matched in strict FIFO order. SQL text is matched by
// substring (case-sensitive). Each expectation can also have an args matcher
// (with_args / with_struct_args) and an injected error. For finer control —
// or when intentionally leaving expectations unconsumed — open without `t`
// and call assert_done yourself.
package sqlmock

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import sql "database:sql"
import drv "database:sql/driver"

// --- Public types ------------------------------------------------------------

Expectation_Kind :: enum {
	Exec,
	Query,
	Prepare,
	Stmt_Exec,
	Stmt_Query,
	Begin,
	Commit,
	Rollback,
}

Args_Predicate :: proc(args: []drv.Value) -> bool

Expectation :: struct {
	mock:       ^Mock, // back-ref so attach procs (returns_rows etc) know the allocator
	kind:       Expectation_Kind,
	sql_match:  string, // substring; "" matches anything
	args_check: Args_Predicate, // optional
	expected_args: []drv.Value, // optional exact-args match (owned); see with_struct_args
	has_expected_args: bool,
	result:     drv.Result, // for Exec/Stmt_Exec
	columns:    []string, // for Query/Stmt_Query (owned)
	rows:       [][]drv.Value, // for Query/Stmt_Query (owned)
	error:      drv.Error, // injected error
	consumed:   bool,
}

Mock :: struct {
	driver:       drv.Driver,
	allocator:    mem.Allocator,
	expectations: [dynamic]^Expectation,
	cursor:       int, // next expectation index
	calls:        [dynamic]Call_Log_Entry, // for diagnostics
	open_db:      ^sql.DB, // back-ref for `close`
	error_msgs:   [dynamic]string, // owned diagnostic strings, freed on close
	t:            ^testing.T, // if non-nil, close() auto-asserts all expectations consumed
	lock_count:   int, // advisory_lock calls (for tests)
	unlock_count: int, // advisory_unlock calls (for tests)
}

Call_Log_Entry :: struct {
	kind: Expectation_Kind,
	sql:  string, // empty for Begin/Commit/Rollback
	matched_idx: int, // -1 if unmatched / failure
}

// --- Lifecycle ---------------------------------------------------------------

// open builds a Mock and an attached `^sql.DB`. Returns both so the test can
// register expectations on `mock` and pass `db` into the code under test.
//
// Pass the test's `t` to have `close` automatically assert that every
// expectation was consumed exactly once — the recommended form in tests:
//
//   m, db := mock.open(t)
//   defer mock.close(m, db)
//
// Omit `t` (just `open()`) when you intentionally leave expectations
// unconsumed (e.g. when testing error paths) and want to assert that yourself.
open :: proc(t: ^testing.T = nil, allocator := context.allocator) -> (mock: ^Mock, db: ^sql.DB) {
	mock = new(Mock, allocator)
	mock.allocator = allocator
	mock.t = t
	mock.driver = drv.Driver{
		data         = mock,
		open         = mock_open,
		close_conn   = mock_close_conn,
		ping         = mock_ping,
		reset        = mock_reset_conn,
		exec         = mock_exec,
		query        = mock_query,
		prepare      = mock_prepare,
		stmt_exec    = mock_stmt_exec,
		stmt_query   = mock_stmt_query,
		stmt_close   = mock_stmt_close,
		stmt_reset   = mock_stmt_reset,
		rows_columns = mock_rows_columns,
		rows_next    = mock_rows_next,
		rows_close   = mock_rows_close,
		begin        = mock_begin,
		tx_commit    = mock_tx_commit,
		tx_rollback  = mock_tx_rollback,
		lock         = mock_lock,
		unlock       = mock_unlock,
	}

	d, err := sql.open(&mock.driver, "mock", allocator)
	if err != nil {
		// Should never happen — mock_open always succeeds.
		panic("sqlmock: failed to open mock DB")
	}
	mock.open_db = d
	return mock, d
}

// close releases the DB and frees mock state. Call once per test. If the mock
// was opened with a testing.T, it first asserts (via testing.expect) that
// every registered expectation was consumed exactly once.
close :: proc(mock: ^Mock, db: ^sql.DB) {
	if mock.t != nil {
		ok, msg := assert_done(mock)
		testing.expect(mock.t, ok, msg)
	}
	sql.close(db)
	for e in mock.expectations {
		for c in e.columns {
			delete(c, mock.allocator)
		}
		delete(e.columns, mock.allocator)
		for row in e.rows {
			for v in row {
				free_value(v, mock.allocator)
			}
			delete(row, mock.allocator)
		}
		delete(e.rows, mock.allocator)
		for v in e.expected_args {
			free_value(v, mock.allocator)
		}
		delete(e.expected_args, mock.allocator)
		free(e, mock.allocator)
	}
	delete(mock.expectations)
	delete(mock.calls)
	for msg in mock.error_msgs {
		delete(msg, mock.allocator)
	}
	delete(mock.error_msgs)
	free(mock, mock.allocator)
}

// clone_value deep-copies a Value's string / []byte payload into `allocator`
// so stored fixtures don't alias caller memory. Other variants are by-value.
@(private)
clone_value :: proc(v: drv.Value, allocator: mem.Allocator) -> drv.Value {
	#partial switch s in v {
	case string:
		return strings.clone(s, allocator)
	case []byte:
		b := make([]byte, len(s), allocator)
		copy(b, s)
		return b
	}
	return v
}

// free_value releases what clone_value allocated for a Value (no-op for
// non-string/bytes variants).
@(private)
free_value :: proc(v: drv.Value, allocator: mem.Allocator) {
	#partial switch s in v {
	case string:
		delete(s, allocator)
	case []byte:
		delete(s, allocator)
	}
}

// fail builds a diagnostic Driver_Error whose message is owned by the mock
// (freed in `close`). Centralizing ownership here avoids the formatted
// strings leaking when a test asserts on an error path.
@(private)
fail :: proc(m: ^Mock, format: string, args: ..any) -> drv.Error {
	msg := fmt.aprintf(format, ..args, allocator = m.allocator)
	append(&m.error_msgs, msg)
	return drv.Driver_Error{code = -1, message = msg}
}

// panic_with_msg formats a message into the mock-owned arena then panics.
// Used for fixture/invariant violations where there is no good error
// channel back to the caller (e.g. inside the driver hot path).
@(private)
panic_with_msg :: proc(m: ^Mock, format: string, args: ..any) -> ! {
	msg := fmt.aprintf(format, ..args, allocator = m.allocator)
	append(&m.error_msgs, msg)
	panic(msg)
}

// --- Internal handle types ---------------------------------------------------

@(private)
Mock_Conn :: struct {
	mock: ^Mock,
}

@(private)
Mock_Stmt :: struct {
	mock:      ^Mock,
	sql:       string, // captured at prepare time, used to match stmt_exec/query
}

@(private)
Mock_Rows :: struct {
	mock:    ^Mock,
	cols:    []drv.Column,
	rows:    [][]drv.Value,
	pos:     int,
}

// --- Matching ----------------------------------------------------------------

@(private)
log_call :: proc(m: ^Mock, kind: Expectation_Kind, sql_text: string, matched_idx: int) {
	append(&m.calls, Call_Log_Entry{kind = kind, sql = sql_text, matched_idx = matched_idx})
}

// next_expectation returns the next un-consumed expectation if its kind and
// SQL match, otherwise an error describing the mismatch.
@(private)
next_expectation :: proc(
	m: ^Mock,
	kind: Expectation_Kind,
	sql_text: string,
	args: []drv.Value,
) -> (
	^Expectation,
	drv.Error,
) {
	if m.cursor >= len(m.expectations) {
		log_call(m, kind, sql_text, -1)
		return nil, fail(m,
			"sqlmock: unexpected %v call (sql=%q); no expectations remain",
			kind, sql_text)
	}
	e := m.expectations[m.cursor]
	if e.kind != kind {
		log_call(m, kind, sql_text, -1)
		return nil, fail(m,
			"sqlmock: expected %v but got %v (sql=%q)",
			e.kind, kind, sql_text)
	}
	if e.sql_match != "" && !strings.contains(sql_text, e.sql_match) {
		log_call(m, kind, sql_text, -1)
		return nil, fail(m,
			"sqlmock: sql mismatch — expected substring %q, got %q",
			e.sql_match, sql_text)
	}
	if e.args_check != nil && !e.args_check(args) {
		log_call(m, kind, sql_text, -1)
		return nil, fail(m,
			"sqlmock: args predicate rejected call to %v (sql=%q)",
			kind, sql_text)
	}
	if e.has_expected_args && !args_equal(e.expected_args, args) {
		log_call(m, kind, sql_text, -1)
		return nil, fail(m,
			"sqlmock: args mismatch for %v — expected %v, got %v",
			kind, e.expected_args, args)
	}

	log_call(m, kind, sql_text, m.cursor)
	e.consumed = true
	m.cursor += 1
	if e.error != nil {
		return e, e.error
	}
	return e, nil
}

// --- Driver vtable -----------------------------------------------------------

@(private)
mock_open :: proc(
	driver_data: rawptr,
	dsn: string,
	allocator: mem.Allocator,
) -> (
	drv.Conn_Handle,
	drv.Error,
) {
	mock := cast(^Mock)driver_data
	conn := new(Mock_Conn, mock.allocator)
	conn.mock = mock
	return drv.Conn_Handle(conn), nil
}

@(private)
mock_close_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Mock_Conn)handle
	free(conn, conn.mock.allocator)
	return nil
}

@(private)
mock_ping  :: proc(handle: drv.Conn_Handle) -> drv.Error {return nil}

// Advisory locking is not expectation-driven — it just records call counts so
// tests can assert the lock/unlock were taken around a migration run.
@(private)
mock_lock :: proc(handle: drv.Conn_Handle, key: i64) -> drv.Error {
	conn := cast(^Mock_Conn)handle
	conn.mock.lock_count += 1
	return nil
}

@(private)
mock_unlock :: proc(handle: drv.Conn_Handle, key: i64) -> drv.Error {
	conn := cast(^Mock_Conn)handle
	conn.mock.unlock_count += 1
	return nil
}
@(private)
mock_reset_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {return nil}

@(private)
mock_exec :: proc(
	handle: drv.Conn_Handle,
	q: string,
	args: []drv.Value,
) -> (
	drv.Result,
	drv.Error,
) {
	conn := cast(^Mock_Conn)handle
	e, err := next_expectation(conn.mock, .Exec, q, args)
	if err != nil {return {}, err}
	return e.result, nil
}

@(private)
mock_query :: proc(
	handle: drv.Conn_Handle,
	q: string,
	args: []drv.Value,
) -> (
	drv.Rows_Handle,
	drv.Error,
) {
	conn := cast(^Mock_Conn)handle
	e, err := next_expectation(conn.mock, .Query, q, args)
	if err != nil {return nil, err}
	return build_rows_handle(conn.mock, e), nil
}

@(private)
build_rows_handle :: proc(m: ^Mock, e: ^Expectation) -> drv.Rows_Handle {
	rows := new(Mock_Rows, m.allocator)
	rows.mock = m
	rows.rows = e.rows
	rows.cols = make([]drv.Column, len(e.columns), m.allocator)
	for c, i in e.columns {
		rows.cols[i] = drv.Column{name = c, nullable = true}
	}
	return drv.Rows_Handle(rows)
}

@(private)
mock_prepare :: proc(handle: drv.Conn_Handle, q: string) -> (drv.Stmt_Handle, drv.Error) {
	conn := cast(^Mock_Conn)handle
	_, err := next_expectation(conn.mock, .Prepare, q, nil)
	if err != nil {return nil, err}
	stmt := new(Mock_Stmt, conn.mock.allocator)
	stmt.mock = conn.mock
	stmt.sql  = q
	return drv.Stmt_Handle(stmt), nil
}

@(private)
mock_stmt_exec :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (drv.Result, drv.Error) {
	stmt := cast(^Mock_Stmt)handle
	e, err := next_expectation(stmt.mock, .Stmt_Exec, stmt.sql, args)
	if err != nil {return {}, err}
	return e.result, nil
}

@(private)
mock_stmt_query :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (drv.Rows_Handle, drv.Error) {
	stmt := cast(^Mock_Stmt)handle
	e, err := next_expectation(stmt.mock, .Stmt_Query, stmt.sql, args)
	if err != nil {return nil, err}
	return build_rows_handle(stmt.mock, e), nil
}

@(private)
mock_stmt_close :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	stmt := cast(^Mock_Stmt)handle
	free(stmt, stmt.mock.allocator)
	return nil
}

@(private)
mock_stmt_reset :: proc(handle: drv.Stmt_Handle) -> drv.Error {return nil}

@(private)
mock_rows_columns :: proc(handle: drv.Rows_Handle) -> []drv.Column {
	rows := cast(^Mock_Rows)handle
	return rows.cols
}

@(private)
mock_rows_next :: proc(handle: drv.Rows_Handle, dest: []drv.Value) -> bool {
	rows := cast(^Mock_Rows)handle
	if rows.pos >= len(rows.rows) {return false}
	src := rows.rows[rows.pos]
	rows.pos += 1
	// returns_rows() validates row shape against columns, so if we get here
	// the only way `len(src) != len(dest)` is a driver/sql bug, not a test
	// fixture mistake. Fail loudly.
	if len(src) != len(dest) {
		panic_with_msg(rows.mock,
			"sqlmock: row width mismatch — dest has %d cols, fixture row has %d",
			len(dest), len(src))
	}
	for i in 0 ..< len(dest) {
		dest[i] = src[i]
	}
	return true
}

@(private)
mock_rows_close :: proc(handle: drv.Rows_Handle) -> drv.Error {
	rows := cast(^Mock_Rows)handle
	delete(rows.cols, rows.mock.allocator)
	free(rows, rows.mock.allocator)
	return nil
}

@(private)
mock_begin :: proc(handle: drv.Conn_Handle, opts: drv.Tx_Options) -> (drv.Tx_Handle, drv.Error) {
	conn := cast(^Mock_Conn)handle
	_, err := next_expectation(conn.mock, .Begin, "", nil)
	if err != nil {return nil, err}
	return drv.Tx_Handle(conn), nil
}

@(private)
mock_tx_commit :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Mock_Conn)handle
	_, err := next_expectation(conn.mock, .Commit, "", nil)
	return err
}

@(private)
mock_tx_rollback :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Mock_Conn)handle
	_, err := next_expectation(conn.mock, .Rollback, "", nil)
	return err
}

// Integration tests for database:sql via the mock driver.
//
// Lives in its own package so it can import both database:sql and
// database:drivers/mock without creating a cycle (the mock already imports
// database:sql).
package sql_tests

import "core:mem"
import "core:testing"
import "core:thread"
import "core:time"

import mock "database:drivers/mock"
import sql "database:sql"
import drv "database:sql/driver"

// --- error-row safety -------------------------------------------------------

// close_row on an error Row (from a no-row query) must be a no-op,
// not a nil-driver crash. Regression test for issue #7.
@(test)
test_close_row_safe_on_no_row :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	// Empty result set — query_row should return Row{err: No_Row, ...}.
	mock.returns_rows(mock.expect_query(m, "SELECT"), {"id"}, {})

	row := sql.query_row(db, "SELECT id FROM users WHERE id = ?", i64(99))
	defer sql.close_row(&row) // must not crash

	_, ok := row.err.(sql.Scan_Error)
	testing.expect(t, ok, "expected Scan_Error on no-row Row")
}

// close_row on an error Row from a driver failure must also be safe.
@(test)
test_close_row_safe_on_driver_error :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	mock.returns_error(
		mock.expect_query(m, "SELECT"),
		drv.Driver_Error{code = 1, message = "boom"},
	)

	row := sql.query_row(db, "SELECT 1")
	defer sql.close_row(&row) // must not crash

	_, ok := row.err.(sql.Driver_Error)
	testing.expect(t, ok, "expected Driver_Error on error Row")
}

// --- error context (query text + call site) ---------------------------------

// Errors surfaced by the sql layer carry the originating query and the
// application call site (Error_Ctx), so failures are traceable without
// the caller threading that context manually.
@(test)
test_error_carries_query_and_call_site :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	mock.returns_error(
		mock.expect_exec(m, "UPDATE"),
		drv.Driver_Error{code = 1, message = "boom"},
	)

	q := "UPDATE users SET name = ? WHERE id = ?"
	_, err := sql.exec(db, q, "alice", i64(1))

	de, ok := err.(sql.Driver_Error)
	testing.expect(t, ok, "expected Driver_Error")
	testing.expect_value(t, de.query, q)
	testing.expect_value(t, de.message, "boom") // driver payload untouched
	testing.expect(
		t,
		de.loc.procedure == "test_error_carries_query_and_call_site",
		"loc should point at this test, the sql.exec call site",
	)

	ctx, has_ctx := sql.error_ctx(err)
	testing.expect(t, has_ctx, "Driver_Error should expose an Error_Ctx")
	testing.expect_value(t, ctx.query, q)
	testing.expect_value(t, sql.error_query(err), q)
}

// A scan mismatch reports the query of the Rows being scanned and the scan
// call site.
@(test)
test_scan_error_carries_query :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	mock.returns_rows(mock.expect_query(m, "SELECT"), {"id"}, {{i64(1)}})

	q := "SELECT id FROM users"
	rows, qerr := sql.query(db, q)
	testing.expect_value(t, qerr, nil)
	defer sql.rows_close(&rows)

	testing.expect(t, sql.next(&rows), "expected one row")

	dest: string // i64 column can't scan into a string
	err := sql.scan(&rows, &dest)

	se, ok := err.(sql.Scan_Error)
	testing.expect(t, ok, "expected Scan_Error")
	testing.expect_value(t, se.kind, sql.Scan_Error_Kind.Column_Type_Mismatch)
	testing.expect_value(t, se.query, q)
	testing.expect(
		t,
		se.loc.procedure == "test_scan_error_carries_query",
		"loc should point at the sql.scan call site",
	)
}

// A successful query_row + scan + close_row must leave nothing allocated.
// Regression test: detach_rows used to mark the Row closed, so close_row
// no-op'd and leaked the cloned column buffers/names on every query_row call.
@(test)
test_query_row_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	UserRow :: struct {
		id:   i64,
		name: string,
	}

	{
		m, db := mock.open(t)
		defer mock.close(m, db)
		mock.returns_structs(mock.expect_query(m, "SELECT"), []UserRow{{id = 1, name = "Alice"}})

		row := sql.query_row(db, "SELECT id, name FROM users WHERE id = ?", i64(1))
		defer sql.close_row(&row)

		u: UserRow
		err := sql.scan(&row, &u)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, u.id, 1)
		testing.expect_value(t, u.name, "Alice")
		delete(u.name) // a scanned string is caller-owned (moved out of the detached Row)
	}

	leaked := len(track.allocation_map)
	testing.expectf(t, leaked == 0, "query_row leaked %d allocation(s)", leaked)
}

// --- pool: max_open + wait timeout -----------------------------------------

@(test)
test_pool_wait_timeout :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	sql.set_max_open_conns(db, 1)
	sql.set_conn_wait_timeout(db, time.Millisecond * 50)

	// Hold one connection — the second checkout must time out.
	conn1, err1 := sql.checkout(db)
	testing.expect_value(t, err1, nil)
	defer sql.checkin(&conn1)

	start := time.now()
	_, err2 := sql.checkout(db)
	elapsed := time.diff(start, time.now())

	pe, is_pe := err2.(sql.Pool_Error)
	testing.expect(t, is_pe && pe == .Timeout, "expected Pool_Error.Timeout")
	testing.expect(t, elapsed >= time.Millisecond * 40, "timeout fired too early")
	testing.expect(t, elapsed < time.Millisecond * 500, "timeout fired suspiciously late")
}

// max_open=1, one holder, another waiter — releasing the conn should
// wake the waiter and let it acquire.
Wait_Probe :: struct {
	db:           ^sql.DB,
	got_conn:     bool,
	acquire_done: sync_barrier,
}

sync_barrier :: struct {
	done: bool,
}

@(test)
test_pool_wait_wakes_on_release :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	sql.set_max_open_conns(db, 1)

	conn1, err1 := sql.checkout(db)
	testing.expect_value(t, err1, nil)

	probe := Wait_Probe {
		db = db,
	}
	worker := thread.create_and_start_with_poly_data(&probe, proc(p: ^Wait_Probe) {
		c, err := sql.checkout(p.db)
		if err == nil {
			p.got_conn = true
			sql.checkin(&c)
		}
		p.acquire_done.done = true
	})
	defer thread.destroy(worker)

	// Give the worker a moment to start waiting.
	time.sleep(time.Millisecond * 20)
	testing.expect(t, !probe.acquire_done.done, "worker should still be waiting")

	sql.checkin(&conn1)

	// Worker should unblock and finish quickly.
	for i in 0 ..< 100 {
		if probe.acquire_done.done {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, probe.got_conn, "worker never acquired the released conn")
}

// --- dynamic column buffer (no more MAX_SCAN_COLS) -------------------------

@(test)
test_many_columns :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	// 80 columns > the old MAX_SCAN_COLS=64. Should no longer corrupt memory.
	N :: 80
	cols: [N]string
	row: [N]drv.Value
	for i in 0 ..< N {
		cols[i] = "c" // duplicated names are fine for this test
		row[i] = i64(i)
	}

	mock.returns_rows(mock.expect_query(m, "SELECT"), cols[:], {row[:]})

	rows, err := sql.query(db, "SELECT * FROM wide")
	testing.expect_value(t, err, nil)
	defer sql.rows_close(&rows)

	testing.expect(t, sql.next(&rows), "expected one row")
	cols_out := sql.columns(&rows)
	testing.expect_value(t, len(cols_out), N)
}

// --- NUMERIC column (integral value stored as INTEGER) scans into a float ---

@(test)
test_scan_integer_into_float :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	Row :: struct {
		n: f64,
	}
	// A NUMERIC/DECIMAL column holding an integral value comes back as i64;
	// it must still scan into an f64 field.
	mock.returns_rows(mock.expect_query(m, "SELECT"), {"n"}, {{i64(42)}})

	rows, err := sql.query(db, "SELECT n FROM t")
	testing.expect_value(t, err, nil)
	defer sql.rows_close(&rows)

	testing.expect(t, sql.next(&rows), "expected a row")
	r: Row
	testing.expect_value(t, sql.scan(&rows, &r), nil)
	testing.expect_value(t, r.n, f64(42))
}

// --- nullable columns scan into Maybe(T) fields ----------------------------

@(test)
test_scan_maybe_fields :: proc(t: ^testing.T) {
	m, db := mock.open(t)
	defer mock.close(m, db)

	Person :: struct {
		id:   i64,
		name: Maybe(string),
		age:  Maybe(i64),
	}

	mock.returns_rows(
		mock.expect_query(m, "SELECT"),
		{"id", "name", "age"},
		{{i64(1), "alice", drv.Null{}}}, // age is NULL
	)

	rows, err := sql.query(db, "SELECT id, name, age FROM people")
	testing.expect_value(t, err, nil)
	defer sql.rows_close(&rows)

	testing.expect(t, sql.next(&rows), "expected one row")

	p: Person
	testing.expect_value(t, sql.scan_struct(&rows, &p), nil)
	defer if n, ok := p.name.?; ok {delete(n)}

	testing.expect_value(t, p.id, i64(1))

	name, name_ok := p.name.?
	testing.expect(t, name_ok, "name should be present")
	testing.expect_value(t, name, "alice")

	_, age_ok := p.age.?
	testing.expect(t, !age_ok, "age should be None for a NULL column")
}

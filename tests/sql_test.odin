// Integration tests for database/sql via the mock driver.
//
// Lives in its own package so it can import both database/sql and
// drivers/mock without creating a cycle (the mock already imports
// database/sql).
package sql_tests

import "core:testing"
import "core:thread"
import "core:time"

import sql "../database/sql"
import drv "../database/sql/driver"
import mock "../drivers/mock"

// --- error-row safety -------------------------------------------------------

// close_row on an error Row (from a no-row query) must be a no-op,
// not a nil-driver crash. Regression test for issue #7.
@(test)
test_close_row_safe_on_no_row :: proc(t: ^testing.T) {
	m, db := mock.open()
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
	m, db := mock.open()
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

// --- pool: max_open + wait timeout -----------------------------------------

@(test)
test_pool_wait_timeout :: proc(t: ^testing.T) {
	m, db := mock.open()
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
	testing.expect(t, elapsed <  time.Millisecond * 500, "timeout fired suspiciously late")
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
	m, db := mock.open()
	defer mock.close(m, db)

	sql.set_max_open_conns(db, 1)

	conn1, err1 := sql.checkout(db)
	testing.expect_value(t, err1, nil)

	probe := Wait_Probe{db = db}
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
	m, db := mock.open()
	defer mock.close(m, db)

	// 80 columns > the old MAX_SCAN_COLS=64. Should no longer corrupt memory.
	N :: 80
	cols: [N]string
	row: [N]drv.Value
	for i in 0 ..< N {
		cols[i] = "c" // duplicated names are fine for this test
		row[i] = i64(i)
	}

	mock.returns_rows(
		mock.expect_query(m, "SELECT"),
		cols[:],
		{row[:]},
	)

	rows, err := sql.query(db, "SELECT * FROM wide")
	testing.expect_value(t, err, nil)
	defer sql.close_rows(&rows)

	testing.expect(t, sql.next(&rows), "expected one row")
	cols_out := sql.columns(&rows)
	testing.expect_value(t, len(cols_out), N)
}

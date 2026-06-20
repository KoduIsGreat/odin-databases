package exec

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "core:time"

import "database:sql"
import sqlite "database:drivers/sqlite"

// --- test 1: a job runs blocking sql and a waiter reads its result ---

Setup_Job :: struct {
	using base: Job,
	n:          i64,
}

setup_run :: proc(jb: ^Job, conn: ^sql.Conn) {
	j := cast(^Setup_Job)jb
	if _, e := sql.exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)"); e != nil {
		j.err = e
		return
	}
	for v in ([]i64{10, 20, 30}) {
		if _, e := sql.exec(conn, "INSERT INTO t (v) VALUES (?)", v); e != nil {
			j.err = e
			return
		}
	}
	row := sql.query_row(conn, "SELECT count(*) FROM t")
	defer sql.close_row(&row)
	n: i64
	if e := sql.scan(&row, &n); e != nil {
		j.err = e
		return
	}
	j.n = n
}

@(test)
test_submit_and_wait :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: Executor
	executor_init(&ex, db, 1, 1, 4, signal_completer())
	defer executor_shutdown(&ex)

	j := new_job(&ex, Setup_Job)
	j.run = setup_run
	testing.expect(t, submit_db(&ex, &j.base))

	wait(&j.base)
	testing.expect_value(t, j.err, nil)
	testing.expect_value(t, j.n, i64(3))
	job_destroy(&j.base)
}

// --- test 2: a multi-statement transaction runs on one pinned connection ---

Tx_Job :: struct {
	using base: Job,
	n:          i64,
}

tx_run :: proc(jb: ^Job, conn: ^sql.Conn) {
	j := cast(^Tx_Job)jb
	if _, e := sql.exec(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY)"); e != nil {
		j.err = e
		return
	}
	tx, terr := sql.begin(conn)
	if terr != nil {
		j.err = terr
		return
	}
	if _, e := sql.exec(&tx, "INSERT INTO t (id) VALUES (1)"); e != nil {
		sql.rollback(&tx)
		j.err = e
		return
	}
	if _, e := sql.exec(&tx, "INSERT INTO t (id) VALUES (2)"); e != nil {
		sql.rollback(&tx)
		j.err = e
		return
	}
	if e := sql.commit(&tx); e != nil {
		j.err = e
		return
	}
	row := sql.query_row(conn, "SELECT count(*) FROM t")
	defer sql.close_row(&row)
	n: i64
	if e := sql.scan(&row, &n); e != nil {
		j.err = e
		return
	}
	j.n = n
}

@(test)
test_multi_step_tx :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: Executor
	executor_init(&ex, db, 1, 1, 4, signal_completer())
	defer executor_shutdown(&ex)

	j := new_job(&ex, Tx_Job)
	j.run = tx_run
	testing.expect(t, submit_db(&ex, &j.base))

	wait(&j.base)
	testing.expect_value(t, j.err, nil)
	testing.expect_value(t, j.n, i64(2))
	job_destroy(&j.base)
}

// --- test 3: cooperative cancellation makes a long run bail early ---

Cancel_Job :: struct {
	using base: Job,
	iters:      int,
	bailed:     bool,
}

cancel_run :: proc(jb: ^Job, conn: ^sql.Conn) {
	j := cast(^Cancel_Job)jb
	for i in 0 ..< 200 {
		if is_cancelled(jb) {
			j.bailed = true
			return
		}
		j.iters = i + 1
		time.sleep(2 * time.Millisecond)
	}
}

@(test)
test_cooperative_cancel :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: Executor
	executor_init(&ex, db, 1, 1, 4, signal_completer())
	defer executor_shutdown(&ex)

	j := new_job(&ex, Cancel_Job)
	j.run = cancel_run
	testing.expect(t, submit_db(&ex, &j.base))

	time.sleep(20 * time.Millisecond)
	cancel(&j.base)

	wait(&j.base)
	testing.expect(t, j.bailed)
	testing.expect(t, j.iters < 200)
	job_destroy(&j.base)
}

// --- test 4: background admission is bounded by bg_cap ---

Bg_Job :: struct {
	using base: Job,
}

bg_run :: proc(jb: ^Job, conn: ^sql.Conn) {
	gate := cast(^sync.Sema)jb.userdata
	sync.sema_wait(gate) // hold the slot until the test releases us
}

@(test)
test_bg_bounded :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: Executor
	executor_init(&ex, db, 1, 2, 2, inline_completer()) // bg_cap = 2
	defer executor_shutdown(&ex)

	gate: sync.Sema

	j1 := new_job(&ex, Bg_Job); j1.run = bg_run; j1.userdata = &gate
	j2 := new_job(&ex, Bg_Job); j2.run = bg_run; j2.userdata = &gate
	j3 := new_job(&ex, Bg_Job); j3.run = bg_run; j3.userdata = &gate

	testing.expect(t, submit_bg(&ex, &j1.base, .IO))
	testing.expect(t, submit_bg(&ex, &j2.base, .IO))
	testing.expect(t, !submit_bg(&ex, &j3.base, .IO)) // at capacity → rejected
	job_destroy(&j3.base) // never submitted; the caller owns it

	sync.sema_post(&gate, 2) // release the two in-flight background jobs
	testing.expect(t, drain(&ex, 2 * time.Second))
}

// --- test 5: inline_completer runs finish on the worker and frees the job ---

Inc_Job :: struct {
	using base: Job,
}

inc_run :: proc(jb: ^Job, conn: ^sql.Conn) {}

inc_finish :: proc(jb: ^Job) {
	p := cast(^int)jb.userdata
	intrinsics.atomic_add(p, 1)
}

@(test)
test_inline_completer :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: Executor
	executor_init(&ex, db, 2, 1, 4, inline_completer())
	defer executor_shutdown(&ex)

	counter: int
	for _ in 0 ..< 5 {
		j := new_job(&ex, Inc_Job)
		j.run = inc_run
		j.finish = inc_finish
		j.userdata = &counter
		testing.expect(t, submit_db(&ex, &j.base))
	}

	testing.expect(t, drain(&ex, 2 * time.Second))
	testing.expect_value(t, intrinsics.atomic_load(&counter), 5)
}

package exec_nbio

import "core:nbio"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "database:exec"
import "database:sql"
import sqlite "database:drivers/sqlite"

// Shared observation block, owned by the test thread and written by callbacks
// that run on the loop thread.
Probe :: struct {
	done:        bool,
	replied:     bool,
	dropped:     bool,
	timed_out:   bool,
	result:      i64,
	finish_tid:  int,
	timeout_tid: int,
}

Req :: struct {
	using req: Request,
	probe:     ^Probe,
	result:    i64,
}

// pump drives the loop until the request is fully resolved (finish always runs,
// and is terminal), with a wall-clock guard so a bug can't hang the suite.
@(private = "file")
pump :: proc(p: ^Probe) {
	start := time.tick_now()
	for !p.done {
		nbio.tick(10 * time.Millisecond)
		if time.tick_since(start) > 3 * time.Second {
			break
		}
	}
}

// --- test 1: completion is delivered to the loop thread ---

query_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	r := cast(^Req)jb
	if _, e := sql.exec(conn, "CREATE TABLE t (x INTEGER)"); e != nil {
		r.err = e
		return
	}
	if _, e := sql.exec(conn, "INSERT INTO t (x) VALUES (?)", i64(7)); e != nil {
		r.err = e
		return
	}
	row := sql.query_row(conn, "SELECT x FROM t")
	defer sql.close_row(&row)
	n: i64
	if e := sql.scan(&row, &n); e != nil {
		r.err = e
		return
	}
	r.result = n
}

reply_finish :: proc(jb: ^exec.Job) {
	r := cast(^Req)jb
	if r.responded {
		r.probe.dropped = true
	} else {
		r.responded = true
		r.probe.result = r.result
		r.probe.replied = true
	}
	r.probe.finish_tid = sync.current_thread_id()
	r.probe.done = true
}

@(test)
test_delivery_on_loop_thread :: proc(t: ^testing.T) {
	testing.expect_value(t, nbio.acquire_thread_event_loop(), nil)
	defer nbio.release_thread_event_loop()

	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: exec.Executor
	exec.executor_init(&ex, db, 1, 1, 4, completer())
	defer exec.executor_shutdown(&ex)

	probe: Probe
	r := exec.new_job(&ex, Req)
	r.probe = &probe
	r.run = query_run
	r.finish = reply_finish

	testing.expect(t, submit_db(&ex, &r.req))
	pump(&probe)

	testing.expect(t, probe.done)
	testing.expect(t, probe.replied)
	testing.expect(t, !probe.dropped)
	testing.expect_value(t, probe.result, i64(7))
	// finish ran on THIS (the loop) thread, not the worker.
	testing.expect_value(t, probe.finish_tid, sync.current_thread_id())
}

// --- test 2: a deadline fires, cancels the job, and the result is dropped ---

slow_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	for _ in 0 ..< 400 {
		if exec.is_cancelled(jb) {
			return
		}
		time.sleep(2 * time.Millisecond)
	}
}

slow_timeout :: proc(rq: ^Request) {
	r := cast(^Req)rq
	r.probe.timed_out = true
	r.probe.timeout_tid = sync.current_thread_id()
}

@(test)
test_deadline_fires :: proc(t: ^testing.T) {
	testing.expect_value(t, nbio.acquire_thread_event_loop(), nil)
	defer nbio.release_thread_event_loop()

	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	ex: exec.Executor
	exec.executor_init(&ex, db, 1, 1, 4, completer())
	defer exec.executor_shutdown(&ex)

	probe: Probe
	r := exec.new_job(&ex, Req)
	r.probe = &probe
	r.run = slow_run
	r.finish = reply_finish
	r.on_timeout = slow_timeout

	testing.expect(t, submit_db(&ex, &r.req, 30 * time.Millisecond))
	pump(&probe)

	testing.expect(t, probe.done)
	testing.expect(t, probe.timed_out) // the deadline produced the response
	testing.expect(t, probe.dropped) // the late completion was dropped
	testing.expect(t, !probe.replied) // no normal reply happened
	testing.expect_value(t, probe.timeout_tid, sync.current_thread_id())
	testing.expect_value(t, probe.finish_tid, sync.current_thread_id())
}

// --- test 3: with two loops sharing one executor, each completion is delivered
// back to the loop that submitted it (not some other loop) ---

ML_Ctx :: struct {
	ex:         ^exec.Executor,
	tid:        int, // this loop thread's id
	finish_tid: int, // the thread finish actually ran on
	done:       bool,
}

ml_run :: proc(jb: ^exec.Job, conn: ^sql.Conn) {
	time.sleep(5 * time.Millisecond) // make sure it really round-trips through a worker
}

ml_finish :: proc(jb: ^exec.Job) {
	r := cast(^Req)jb
	ctx := cast(^ML_Ctx)r.userdata
	ctx.finish_tid = sync.current_thread_id()
	ctx.done = true
}

ml_loop_thread :: proc(ctx: ^ML_Ctx) {
	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()
	ctx.tid = sync.current_thread_id()

	r := exec.new_job(ctx.ex, Req)
	r.run = ml_run
	r.finish = ml_finish
	r.userdata = rawptr(ctx)
	submit_db(ctx.ex, &r.req) // binds r.loop to THIS thread's loop

	start := time.tick_now()
	for !ctx.done {
		nbio.tick(5 * time.Millisecond)
		if time.tick_since(start) > 3 * time.Second {
			break
		}
	}
}

@(test)
test_multi_loop_delivery :: proc(t: ^testing.T) {
	db, oerr := sql.open(&sqlite.driver, ":memory:")
	testing.expect_value(t, oerr, nil)

	// One shared executor, two independent nbio loops on two threads.
	ex: exec.Executor
	exec.executor_init(&ex, db, 2, 2, 4, completer())
	defer exec.executor_shutdown(&ex)

	a := ML_Ctx{ex = &ex}
	b := ML_Ctx{ex = &ex}

	ta := thread.create_and_start_with_poly_data(&a, ml_loop_thread)
	tb := thread.create_and_start_with_poly_data(&b, ml_loop_thread)
	thread.join(ta)
	thread.join(tb)
	thread.destroy(ta)
	thread.destroy(tb)

	testing.expect(t, a.done)
	testing.expect(t, b.done)
	testing.expect(t, a.tid != b.tid)
	// the key assertion: each request's finish ran on ITS OWN loop thread.
	testing.expect_value(t, a.finish_tid, a.tid)
	testing.expect_value(t, b.finish_tid, b.tid)
}

// Package exec_nbio bridges database:exec to a core:nbio event loop — phase 2a
// of the laytan-http integration. It is the (optional) piece that makes the
// async executor drive a single-threaded, non-blocking server: a worker runs
// the blocking query, then the result is delivered back onto the loop thread so
// the response is written there, plus per-request deadlines/cancellation.
//
// It depends on core:nbio but NOT on any HTTP library: the HTTP handler layer
// (router, Request/Response, respond_json) sits on top of this and is the only
// part that needs odin-http. Here, finish() is where a handler would write its
// response; on_timeout() is where it would write a 504.
//
// Threading contract (the reason this is split the way it is):
//
//   - nbio operations must be ALLOCATED on the loop thread (the op pool is not
//     thread-safe), but exec() of an already-allocated op is safe from another
//     thread (it enqueues onto a lock-free queue and wakes the loop). So submit
//     PREPS the completion op on the loop thread, and the worker only EXECS it.
//   - finish, on_timeout, and the deadline all run on the LOOP thread. run()
//     runs on a worker thread. The worker only ever touches the job's cancelled
//     flag and connection handle (both atomic, via database:exec).
//
// Embed Request as the first field of your handler job, exactly as you would
// embed exec.Job directly.
package exec_nbio

import "core:nbio"
import "core:time"

import "database:exec"

// Request is the job base for nbio-driven handlers. It adds the per-request
// state the bridge needs: the originating loop, the pre-allocated completion op,
// an optional deadline timer, a one-shot responded guard, and a timeout callback.
//
// `loop` is set by submit() to whatever loop is current on the calling (handler)
// thread — so this works unchanged whether the server runs one nbio loop or one
// per core: each request's completion is routed back to the loop that owns its
// connection, never some other loop's.
//
// `responded` is owned by the loop thread. Both finish and on_timeout must
// honour it so exactly one response is produced: a normal reply OR a 504, never
// both.
Request :: struct {
	using job:  exec.Job,
	loop:       ^nbio.Event_Loop, // set by submit() to the calling thread's loop
	completion: ^nbio.Operation, // prepped on the loop thread; exec'd from the worker
	deadline:   ^nbio.Operation, // armed deadline timer, or nil
	responded:  bool, // loop-thread only: has a response been produced yet
	on_timeout: proc(r: ^Request), // called on the loop thread when the deadline fires
}

// completer returns an exec.Completer that delivers each finished job back onto
// the loop that submitted it (carried per-request on r.completion), so a single
// shared executor can serve any number of nbio loops. REQUIRES every job
// submitted under it to embed Request as its first field (submit() does that).
//
// The shared executor's allocator must be thread-safe when more than one loop
// submits concurrently (the default heap allocator is).
completer :: proc() -> exec.Completer {
	return exec.Completer{data = nil, notify = on_worker_complete}
}

// submit arms the request and queues it on the given lane. dur > 0 sets a
// deadline: if it elapses before the job finishes, on_timeout runs on the loop
// thread (write a 504) and the in-flight query is interrupted; the eventual
// completion is then dropped without a second response. MUST be called on the
// loop thread (it allocates nbio ops).
//
// Returns false if the executor rejected the job (draining). On false the caller
// still owns the Request and MUST free it with exec.job_destroy(&r.job) (the
// nbio ops submit prepped are already reclaimed here); on true, the bridge frees
// the job after finish runs.
submit :: proc(
	ex: ^exec.Executor,
	r: ^Request,
	lane: exec.Lane,
	dur: time.Duration = 0,
) -> bool {
	// Bind to the loop running on THIS (the handler's) thread, so the completion
	// returns here even with one loop per core. Allocate the completion op on
	// this loop; the worker will only exec it. Carry the job pointer in the op.
	r.loop = nbio.current_thread_event_loop()
	r.completion = nbio.prep_next_tick(on_loop_finish, r.loop)
	r.completion.user_data[0] = rawptr(&r.job)

	if dur > 0 {
		r.deadline = nbio.timeout_poly(dur, r, on_deadline, r.loop)
	}

	ok: bool
	switch lane {
	case .DB:
		ok = exec.submit_db(ex, &r.job)
	case .IO:
		ok = exec.submit_io(ex, &r.job)
	}

	if !ok {
		if r.deadline != nil {
			nbio.remove(r.deadline)
			r.deadline = nil
		}
		nbio.reattach(r.completion) // return the never-exec'd op to the pool
		r.completion = nil
		return false
	}
	return true
}

// submit_db / submit_io are lane-specific conveniences over submit.
submit_db :: proc(ex: ^exec.Executor, r: ^Request, dur: time.Duration = 0) -> bool {
	return submit(ex, r, .DB, dur)
}

submit_io :: proc(ex: ^exec.Executor, r: ^Request, dur: time.Duration = 0) -> bool {
	return submit(ex, r, .IO, dur)
}

// on_worker_complete runs on a WORKER thread when run() returns. It only execs
// the pre-allocated completion op — a lock-free enqueue onto that op's own loop
// (r.loop) plus a wake_up — so the completion lands on the loop that submitted
// the request, and no nbio allocation happens off the loop thread.
@(private)
on_worker_complete :: proc(data: rawptr, job: ^exec.Job) {
	r := cast(^Request)job
	nbio.exec(r.completion)
}

// on_loop_finish runs on the LOOP thread (driven by the exec'd completion op).
// It is terminal: it cancels any pending deadline, runs finish (which guards on
// `responded`, so a timed-out request just drops its result), and frees the job.
// nbio reclaims the completion op itself after this callback returns.
@(private)
on_loop_finish :: proc(op: ^nbio.Operation) {
	job := cast(^exec.Job)op.user_data[0]
	r := cast(^Request)job

	if r.deadline != nil {
		nbio.remove(r.deadline)
		r.deadline = nil
	}
	if job.finish != nil {
		job.finish(job)
	}
	exec.job_destroy(job)
}

// on_deadline runs on the LOOP thread when the deadline elapses before the job
// finishes. It produces the early (504) response, interrupts the in-flight query,
// and leaves the job for on_loop_finish to free once the worker returns.
@(private)
on_deadline :: proc(op: ^nbio.Operation, r: ^Request) {
	if r.responded {
		return
	}
	r.responded = true
	r.deadline = nil // it fired; nothing to remove later
	exec.cancel(&r.job) // cooperative flag + interrupt the running query
	if r.on_timeout != nil {
		r.on_timeout(r)
	}
}

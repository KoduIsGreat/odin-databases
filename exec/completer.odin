package exec

import "core:sync"

// inline_completer runs finish on the worker thread and then frees the job. Use
// it for fire-style request handling where finish itself performs the side
// effect (write a response, emit a log) and nothing needs to wait. This is the
// "phase 1" completer that needs no event loop; a future nbio completer would
// instead defer finish onto the loop thread.
inline_completer :: proc() -> Completer {
	return Completer{data = nil, notify = inline_notify}
}

@(private)
inline_notify :: proc(_: rawptr, job: ^Job) {
	if job.finish != nil {
		job.finish(job)
	}
	job_destroy(job)
}

// signal_completer wakes a caller blocked in wait(job) and leaves the job
// intact so that caller can read its result and then job_destroy it. finish is
// NOT invoked — the waiter inspects the job's fields directly. Use it for
// synchronous request/response code and tests.
//
// The scanned result lives in the job's arena until job_destroy, so the waiter
// must read (or copy out) before destroying.
signal_completer :: proc() -> Completer {
	return Completer{data = nil, notify = signal_notify}
}

@(private)
signal_notify :: proc(_: rawptr, job: ^Job) {
	sync.sema_post(&job.done)
}

// wait blocks until a job submitted under signal_completer has completed. After
// it returns, read job.err and the job's outputs, then job_destroy(job).
wait :: proc(job: ^Job) {
	sync.sema_wait(&job.done)
}

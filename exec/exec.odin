// Package exec is an asynchronous execution layer over database:sql. It runs
// blocking database work on a pool of worker threads so a single-threaded
// caller (e.g. a non-blocking HTTP event loop) is never stalled by a query.
//
// The core idea is a Job split into two halves:
//
//   - run(j, conn): the BLOCKING work — runs on a worker thread. It may issue
//     any number of synchronous sql calls (queries, a multi-statement
//     transaction, business logic) against the connection it is handed. This
//     is plain sequential code; the "async" boundary is paid once, here.
//   - finish(j):    DELIVER the result — runs wherever the Completer decides.
//     It must not block or touch the database. With inline_completer it runs on
//     the worker; a future nbio completer would run it on the loop thread.
//
// Connections are PINNED one-per-DB-worker via the thread pool's start/stop
// hooks (see db_worker_init / db_worker_fini). A run therefore always operates
// on a single, stable connection for its whole duration — which makes
// multi-statement transactions and connection-scoped state (last_insert_rowid,
// temp tables) correct, and makes the connection knowable to a watchdog thread
// for cancellation. The worker->connection map is published once at startup, so
// cancellation reads it without any per-submit bookkeeping.
//
// Two lanes isolate workloads: DB work and outbound I/O (calls to other
// services) draw from separate pools, so a slow external call can never starve
// queries. Fire-and-forget background work goes through a bounded admission
// gate (bg_cap) so a burst cannot saturate the pool.
//
// SQLite note: a pinned-connection executor opens one connection per worker, so
// a ":memory:" DSN gives each worker its OWN empty database. Use a file DSN (or
// a single DB worker) when workers must share data.
package exec

import "base:intrinsics"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "core:time"

import "database:sql"

// Lane selects which worker pool a job runs on.
//   - .DB: holds a pinned database connection; for queries/transactions.
//   - .IO: holds no connection; for blocking calls to other services.
Lane :: enum {
	DB,
	IO,
}

// Job is the unit of work. Embed it as the FIRST field of your own job struct
// (`using base: exec.Job`) so a pointer to your struct can be passed where a
// ^Job is expected and recovered with a cast inside run/finish. Allocate via
// new_job so the per-job arena and owning allocator are set up.
Job :: struct {
	// --- set by the framework ---
	exec:       ^Executor,
	lane:       Lane,
	background: bool,
	arena:      virtual.Arena, // per-job scratch; scan output lives here
	done:       sync.Sema, // posted by signal_completer; waited on by wait()

	// --- provided by the caller ---
	// run executes the blocking work on a worker thread. conn is the worker's
	// pinned connection on the DB lane, or nil on the IO lane.
	run:        proc(j: ^Job, conn: ^sql.Conn),
	// finish delivers the result. May be nil. Must not block or use the DB.
	finish:     proc(j: ^Job),
	userdata:   rawptr, // optional handler payload (alternative to embedding). Named
	// `userdata`, not `user`, so it does not collide with common embedder field names.

	// --- result ---
	err:        sql.Error,

	// --- cancellation (atomic) ---
	cancelled:   bool,
	conn_handle: sql.Conn_Handle, // the connection run() is using, for interrupt
}

// Completer decides what happens to a (non-background) job after run returns,
// and on which thread. notify is called once per job. Built-in completers:
// inline_completer (finish + free on the worker) and signal_completer (wake a
// wait()er and hand the job back to the caller). See completer.odin.
Completer :: struct {
	data:   rawptr,
	notify: proc(data: rawptr, job: ^Job),
}

// Executor owns the worker pools, the pinned connections, and the background
// admission gate. Construct with executor_init; tear down with executor_shutdown.
Executor :: struct {
	db:        ^sql.DB,
	db_pool:   thread.Pool,
	io_pool:   thread.Pool,
	completer: Completer,

	// worker->connection map, published once at startup (indexed by the worker's
	// stable thread.user_index). Read on cancellation; never written per-submit.
	worker_conns: []sql.Conn_Handle,

	draining:    bool, // atomic — stops new admission; signals cooperative cancel
	bg_inflight: int, // atomic — current detached jobs
	bg_cap:      int,
	alloc:       mem.Allocator,
}

// executor_init starts the worker pools. It pins one connection per DB worker
// and sets the sql pool's max_open to db_workers so those checkouts neither
// block nor exceed the budget. io_workers handle the IO lane (no connection).
// bg_cap caps in-flight fire-and-forget jobs. The completer governs delivery of
// request jobs (see Completer).
executor_init :: proc(
	ex: ^Executor,
	db: ^sql.DB,
	db_workers: int,
	io_workers: int,
	bg_cap: int,
	completer: Completer,
	allocator := context.allocator,
) {
	ex.db = db
	ex.completer = completer
	ex.bg_cap = bg_cap
	ex.alloc = allocator
	ex.worker_conns = make([]sql.Conn_Handle, db_workers, allocator)

	// One pinned connection per DB worker.
	sql.set_max_open_conns(db, db_workers)

	thread.pool_init(&ex.db_pool, allocator, db_workers, db_worker_init, ex, db_worker_fini, ex)
	thread.pool_init(&ex.io_pool, allocator, io_workers)
	thread.pool_start(&ex.db_pool)
	thread.pool_start(&ex.io_pool)
}

// db_worker_init runs once per DB worker, before it processes any task. It
// checks out the worker's pinned connection and publishes its handle. Because
// the init hook completes before the worker's task loop begins, any job that
// later runs on this worker is guaranteed to see tls_ok == true.
@(private)
db_worker_init :: proc(t: ^thread.Thread, data: rawptr) {
	ex := cast(^Executor)data
	conn, err := sql.checkout(ex.db)
	if err != nil {
		// Leave tls_ok false: jobs on this worker fail fast (conn_unavailable).
		return
	}
	tls_conn = conn
	tls_ok = true
	ex.worker_conns[t.user_index] = conn.handle
}

// db_worker_fini runs once per DB worker at shutdown (during pool join) and
// returns the pinned connection to the pool — so by the time the join completes,
// every connection is checked in and sql.close is safe.
@(private)
db_worker_fini :: proc(t: ^thread.Thread, data: rawptr) {
	ex := cast(^Executor)data
	if tls_ok {
		sql.checkin(&tls_conn)
		tls_ok = false
	}
	ex.worker_conns[t.user_index] = nil
}

// The worker's pinned connection lives in thread-local storage. DB-pool workers
// set it in their init hook; IO-pool workers (and any non-pool thread) leave it
// zero, so tls_ok stays false and run() receives a nil conn there.
@(thread_local) tls_conn: sql.Conn
@(thread_local) tls_ok: bool

// worker_entry is the single task body for every job. It points the context
// allocator at the job's arena (so scan output is reclaimed with the job),
// publishes the connection handle for cancellation, runs the work, then routes
// completion: background jobs finish-and-free here; request jobs go to the
// completer.
@(private)
worker_entry :: proc(t: thread.Task) {
	job := cast(^Job)t.data

	ctx := context
	ctx.allocator = virtual.arena_allocator(&job.arena)
	context = ctx

	conn: ^sql.Conn = nil
	if tls_ok {
		conn = &tls_conn
		intrinsics.atomic_store(&job.conn_handle, tls_conn.handle)
	}

	if job.run != nil {
		job.run(job, conn)
	}

	intrinsics.atomic_store(&job.conn_handle, nil)
	complete(job)
}

@(private)
complete :: proc(job: ^Job) {
	ex := job.exec
	if job.background {
		if job.finish != nil {
			job.finish(job)
		}
		job_destroy(job)
		intrinsics.atomic_sub(&ex.bg_inflight, 1)
		return
	}
	ex.completer.notify(ex.completer.data, job)
}

// new_job allocates a job of your type T (which must embed Job as its first
// field), wiring its owning allocator, executor, and per-job arena. Set run/
// finish and any inputs, then hand &job.base to a submit_* proc.
new_job :: proc(ex: ^Executor, $T: typeid) -> ^T {
	j := new(T, ex.alloc)
	base := cast(^Job)j
	base.exec = ex
	_ = virtual.arena_init_growing(&base.arena)
	return j
}

// job_destroy releases a job's arena and the job itself. Called automatically
// by inline_completer and by the background path; call it yourself after wait()
// when using signal_completer.
job_destroy :: proc(job: ^Job) {
	alloc := job.exec.alloc
	virtual.arena_destroy(&job.arena)
	free(job, alloc)
}

// --- Submission ---

// submit_db queues a job on the DB lane. Returns false if the executor is
// draining (the caller then owns the job — job_destroy it).
submit_db :: proc(ex: ^Executor, job: ^Job) -> bool {
	return dispatch(ex, job, .DB, false)
}

// submit_io queues a job on the IO lane (no database connection). Returns false
// if draining.
submit_io :: proc(ex: ^Executor, job: ^Job) -> bool {
	return dispatch(ex, job, .IO, false)
}

// submit_bg queues detached, fire-and-forget work on the given lane, bounded by
// bg_cap in-flight jobs. Returns false if draining or at capacity — the caller
// then owns the job and decides whether to drop, defer, or shed load. Background
// jobs report via their finish (logging), not a response, and must own their
// inputs (never the request arena of whatever submitted them).
submit_bg :: proc(ex: ^Executor, job: ^Job, lane: Lane) -> bool {
	if intrinsics.atomic_load(&ex.draining) {
		return false
	}
	// Non-blocking admission: claim a slot or reject.
	for {
		cur := intrinsics.atomic_load(&ex.bg_inflight)
		if cur >= ex.bg_cap {
			return false
		}
		if _, ok := intrinsics.atomic_compare_exchange_weak(&ex.bg_inflight, cur, cur + 1); ok {
			break
		}
	}
	if !dispatch(ex, job, lane, true) {
		intrinsics.atomic_sub(&ex.bg_inflight, 1) // dispatch rejected — release the slot
		return false
	}
	return true
}

@(private)
dispatch :: proc(ex: ^Executor, job: ^Job, lane: Lane, background: bool) -> bool {
	if intrinsics.atomic_load(&ex.draining) {
		return false
	}
	job.exec = ex
	job.lane = lane
	job.background = background
	pool := &ex.db_pool if lane == .DB else &ex.io_pool
	thread.pool_add_task(pool, ex.alloc, worker_entry, job)
	return true
}

// --- Cancellation ---

// is_cancelled reports whether a job has been individually cancelled or the
// executor is draining. Long-running run() bodies should poll it between steps
// to bail out early (cooperative cancellation).
is_cancelled :: proc(job: ^Job) -> bool {
	return intrinsics.atomic_load(&job.cancelled) || intrinsics.atomic_load(&job.exec.draining)
}

// cancel requests cancellation of a single in-flight job: it sets the
// cooperative flag and, if the job is mid-query on a connection whose driver
// supports it, interrupts that query (which returns a driver error). Safe to
// call from any thread. A query already returned, or a driver without interrupt
// support, simply relies on the cooperative flag.
cancel :: proc(job: ^Job) {
	intrinsics.atomic_store(&job.cancelled, true)
	if h := intrinsics.atomic_load(&job.conn_handle); h != nil {
		sql.interrupt(job.exec.db, h)
	}
}

// cancel_all_inflight interrupts every pinned connection. Used at shutdown to
// unstick workers running slow queries so the pool can join promptly.
@(private)
cancel_all_inflight :: proc(ex: ^Executor) {
	for h in ex.worker_conns {
		if h != nil {
			sql.interrupt(ex.db, h)
		}
	}
}

// --- Lifecycle ---

// drain waits until no jobs are queued or running on either pool, or until the
// timeout elapses. Returns true if fully drained. Call it before
// executor_shutdown for a graceful stop that lets queued work complete rather
// than dropping it. reap() is called along the way to release finished Task
// records.
drain :: proc(ex: ^Executor, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for thread.pool_num_outstanding(&ex.db_pool) > 0 ||
	    thread.pool_num_outstanding(&ex.io_pool) > 0 {
		if time.tick_since(start) >= timeout {
			return false
		}
		reap(ex)
		time.sleep(1 * time.Millisecond)
	}
	reap(ex)
	return true
}

// reap discards finished Task bookkeeping from both pools. A long-running
// server should call it periodically (the pool retains a record per completed
// task until popped); our Job memory is freed separately on completion.
reap :: proc(ex: ^Executor) {
	for {
		if _, ok := thread.pool_pop_done(&ex.db_pool); !ok {
			break
		}
	}
	for {
		if _, ok := thread.pool_pop_done(&ex.io_pool); !ok {
			break
		}
	}
}

// executor_shutdown stops the executor and closes the database. It marks the
// executor draining (rejecting new submits), interrupts in-flight queries, then
// joins both pools — which finishes started tasks and runs the fini hooks that
// check every pinned connection back in. Only then is sql.close called, since
// closing frees the DB while a live worker could still touch it.
//
// Queued-but-unstarted tasks are dropped (their job memory is not reclaimed);
// call drain() first if you need queued work to complete.
executor_shutdown :: proc(ex: ^Executor) {
	intrinsics.atomic_store(&ex.draining, true)
	cancel_all_inflight(ex)

	thread.pool_join(&ex.db_pool)
	thread.pool_join(&ex.io_pool)

	reap(ex)

	sql.close(ex.db) // safe only after the joins: no worker can touch db now

	thread.pool_destroy(&ex.db_pool)
	thread.pool_destroy(&ex.io_pool)
	delete(ex.worker_conns, ex.alloc)
}

package sql

import "core:mem"
import "core:sync"
import "core:time"

// --- Overloaded public API ---
// These dispatch on the first parameter type (^DB, ^Conn, ^Tx).

exec :: proc {
	db_exec,
	conn_exec,
	tx_exec,
}
query :: proc {
	db_query,
	conn_query,
	tx_query,
}
prepare :: proc {
	conn_prepare,
	tx_prepare,
}
begin :: proc {
	db_begin,
	conn_begin,
}
query_row :: proc {
	db_query_row,
	conn_query_row,
	tx_query_row,
}

// --- DB ---

// DB is a database handle with an underlying connection pool.
// It is safe to use from multiple threads.
//
// Pool semantics:
//   - max_open = 0 (default): unlimited; acquire never blocks.
//   - max_open > 0: acquire blocks on a condvar when the cap is reached.
//     wait_timeout caps the block (0 = wait forever); Pool_Error.Timeout is
//     returned once it expires.
DB :: struct {
	driver:       ^Driver,
	dsn:          string,
	allocator:    mem.Allocator,

	// Pool state — protected by mu
	mu:           sync.Mutex,
	cond:         sync.Cond, // signalled on pool_release / close / cap change
	free_conns:   [dynamic]Pool_Conn,
	num_open:     int,
	max_open:     int,
	max_idle:     int,
	max_lifetime: time.Duration,
	wait_timeout: time.Duration,
	closed:       bool,
}

@(private)
Pool_Conn :: struct {
	handle:     Conn_Handle,
	created_at: time.Time,
}

// open creates a new DB handle. No connections are opened until first use.
// The provided allocator is used for pool internals and driver connections.
// Scan output (cloned strings and []byte) uses context.allocator at the
// call site, so callers can control scan memory separately (e.g. with an arena).
open :: proc(driver: ^Driver, dsn: string, allocator := context.allocator) -> (^DB, Error) {
	db := new(DB, allocator)
	db.driver = driver
	db.dsn = dsn
	db.allocator = allocator
	db.max_open = 0 // unlimited
	db.max_idle = 2
	db.free_conns = make([dynamic]Pool_Conn, allocator)
	return db, nil
}

// close closes the database, releasing all pooled connections.
// Concurrent acquirers are woken with Pool_Error.Closed.
close :: proc(db: ^DB) -> Error {
	sync.mutex_lock(&db.mu)
	if db.closed {
		sync.mutex_unlock(&db.mu)
		return Pool_Error.Closed
	}
	db.closed = true

	// Take ownership of the free list under the lock, drop it, then close
	// handles and free the struct — closing handles or freeing memory while
	// holding db.mu would block other operations and (worse) the eventual
	// free would race the lock's own state.
	to_close := db.free_conns
	db.free_conns = nil
	db.num_open -= len(to_close)
	driver := db.driver
	allocator := db.allocator
	sync.cond_broadcast(&db.cond) // wake any waiters so they observe `closed`.
	sync.mutex_unlock(&db.mu)

	for pc in to_close {
		driver.close_conn(pc.handle)
	}
	delete(to_close)
	free(db, allocator)
	return nil
}

// --- Pool configuration ---

set_max_open_conns :: proc(db: ^DB, n: int) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.max_open = n
	sync.cond_broadcast(&db.cond) // raising the cap may unblock waiters
}

// set_max_idle_conns updates the idle cap and closes any excess connections.
set_max_idle_conns :: proc(db: ^DB, n: int) {
	sync.mutex_lock(&db.mu)
	db.max_idle = n
	to_close: [dynamic]Pool_Conn
	for len(db.free_conns) > n {
		append(&to_close, pop(&db.free_conns))
	}
	db.num_open -= len(to_close)
	driver := db.driver
	sync.cond_broadcast(&db.cond)
	sync.mutex_unlock(&db.mu)

	for pc in to_close {
		driver.close_conn(pc.handle)
	}
	delete(to_close)
}

set_conn_max_lifetime :: proc(db: ^DB, d: time.Duration) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.max_lifetime = d
}

// set_conn_wait_timeout caps how long pool_acquire will block when max_open
// is reached. 0 (default) means wait forever; any positive duration returns
// Pool_Error.Timeout once exceeded.
set_conn_wait_timeout :: proc(db: ^DB, d: time.Duration) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.wait_timeout = d
}

// prune_idle closes every idle connection in the pool. Connections that
// are currently checked out are unaffected.
prune_idle :: proc(db: ^DB) {
	sync.mutex_lock(&db.mu)
	to_close := db.free_conns
	db.free_conns = make([dynamic]Pool_Conn, db.allocator)
	db.num_open -= len(to_close)
	driver := db.driver
	sync.cond_broadcast(&db.cond)
	sync.mutex_unlock(&db.mu)

	for pc in to_close {
		driver.close_conn(pc.handle)
	}
	delete(to_close)
}

// --- Convenience operations (auto checkout/checkin) ---

ping :: proc(db: ^DB) -> Error {
	conn, created_at, err := pool_acquire(db)
	if err != nil {return err}
	defer pool_release(db, conn, created_at)
	return db.driver.ping(conn)
}

@(private)
db_exec :: proc(
	db: ^DB,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Result,
	Error,
) {
	conn, created_at, err := pool_acquire(db)
	if err != nil {return {}, err}
	defer pool_release(db, conn, created_at)
	result, eerr := db.driver.exec(conn, query_str, args)
	if eerr != nil {return {}, with_query(eerr, query_str, loc)}
	return result, nil
}

// Convenience query — the returned Rows owns the connection and
// releases it back to the pool on rows_close().
@(private)
db_query :: proc(
	db: ^DB,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Rows,
	Error,
) {
	conn, created_at, cerr := pool_acquire(db)
	if cerr != nil {return {}, cerr}

	handle, qerr := db.driver.query(conn, query_str, args)
	if qerr != nil {
		pool_release(db, conn, created_at)
		return {}, with_query(qerr, query_str, loc)
	}

	return Rows {
			db         = db, // non-nil = Rows owns the conn
			conn       = conn,
			handle     = handle,
			driver     = db.driver,
			created_at = created_at,
			query      = query_str,
			loc        = loc,
		}, nil
}

// --- Connection pool internals ---

// pool_acquire returns a connection handle and its creation time. The
// creation time must be passed back to pool_release so max_lifetime fires
// at the right moment.
//
// When max_open is reached the call blocks on db.cond until a release
// signals it, the DB is closed, or wait_timeout expires (0 = forever).
@(private)
pool_acquire :: proc(db: ^DB) -> (Conn_Handle, time.Time, Error) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)

	deadline: time.Time
	have_deadline := false

	for {
		if db.closed {
			return nil, {}, Pool_Error.Closed
		}

		now := time.now()

		// Try to reuse a pooled connection (LIFO — freshest first).
		// Skip + close any that exceeded max_lifetime.
		for len(db.free_conns) > 0 {
			pc := pop(&db.free_conns)
			if db.max_lifetime > 0 && time.diff(pc.created_at, now) > db.max_lifetime {
				db.num_open -= 1
				// Closing under the lock is acceptable — close_conn is a
				// quick C call, and releasing the lock here would re-open
				// the race for other acquirers.
				db.driver.close_conn(pc.handle)
				continue
			}
			return pc.handle, pc.created_at, nil
		}

		if db.max_open == 0 || db.num_open < db.max_open {
			db.num_open += 1
			driver := db.driver
			dsn := db.dsn
			allocator := db.allocator
			//TODO (this seems hacky) Drop the lock for the (slow) open() call.
			sync.mutex_unlock(&db.mu)
			handle, err := driver.open(driver.data, dsn, allocator)
			sync.mutex_lock(&db.mu)
			if err != nil {
				db.num_open -= 1
				sync.cond_broadcast(&db.cond)
				return nil, {}, err
			}
			return handle, now, nil
		}

		// max_open reached — block on cond until a release or close.
		if db.wait_timeout > 0 {
			if !have_deadline {
				deadline = time.time_add(now, db.wait_timeout)
				have_deadline = true
			}
			remaining := time.diff(now, deadline)
			if remaining <= 0 {
				return nil, {}, Pool_Error.Timeout
			}
			_ = sync.cond_wait_with_timeout(&db.cond, &db.mu, remaining)
			// Loop re-checks closed, free list, and deadline.
		} else {
			sync.cond_wait(&db.cond, &db.mu)
		}
	}
}

@(private)
pool_release :: proc(db: ^DB, conn: Conn_Handle, created_at: time.Time) {
	sync.mutex_lock(&db.mu)

	if db.closed {
		db.num_open -= 1
		driver := db.driver
		sync.cond_broadcast(&db.cond)
		sync.mutex_unlock(&db.mu)
		driver.close_conn(conn)
		return
	}

	if len(db.free_conns) < db.max_idle {
		append(&db.free_conns, Pool_Conn{handle = conn, created_at = created_at})
		sync.cond_signal(&db.cond)
		sync.mutex_unlock(&db.mu)
		return
	}

	// Over the idle cap — close this one. Still signal so a waiter can
	// open a fresh connection (num_open just dropped).
	db.num_open -= 1
	driver := db.driver
	sync.cond_signal(&db.cond)
	sync.mutex_unlock(&db.mu)
	driver.close_conn(conn)
}

// pool_discard closes the connection unconditionally instead of returning
// it to the pool. Used when the connection is known to be in a bad state
// (e.g. a failed commit / rollback) and must not be reused.
@(private)
pool_discard :: proc(db: ^DB, conn: Conn_Handle) {
	sync.mutex_lock(&db.mu)
	db.num_open -= 1
	driver := db.driver
	sync.cond_signal(&db.cond)
	sync.mutex_unlock(&db.mu)
	driver.close_conn(conn)
}

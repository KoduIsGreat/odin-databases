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

// --- DB ---

// DB is a database handle with an underlying connection pool.
// It is safe to use from multiple threads.
DB :: struct {
	driver:       ^Driver,
	dsn:          string,
	allocator:    mem.Allocator,

	// Pool state — protected by mu
	mu:           sync.Mutex,
	free_conns:   [dynamic]Pool_Conn,
	num_open:     int,
	max_open:     int, // 0 = unlimited
	max_idle:     int,
	max_lifetime: time.Duration,
	closed:       bool,
}

@(private)
Pool_Conn :: struct {
	handle:     Conn_Handle,
	created_at: time.Time,
}

// open creates a new DB handle. No connections are opened until first use.
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
close :: proc(db: ^DB) -> Error {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)

	if db.closed {
		return Pool_Error.Closed
	}
	db.closed = true

	for &pc in db.free_conns {
		db.driver.close_conn(pc.handle)
		db.num_open -= 1
	}
	delete(db.free_conns)
	free(db, db.allocator)
	return nil
}

// --- Pool configuration ---

set_max_open_conns :: proc(db: ^DB, n: int) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.max_open = n
}

set_max_idle_conns :: proc(db: ^DB, n: int) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.max_idle = n
}

set_conn_max_lifetime :: proc(db: ^DB, d: time.Duration) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)
	db.max_lifetime = d
}

// --- Convenience operations (auto checkout/checkin) ---

ping :: proc(db: ^DB) -> Error {
	conn, _, err := pool_acquire(db)
	if err != nil {return err}
	defer pool_release(db, conn, time.now())
	return db.driver.ping(conn)
}

@(private)
db_exec :: proc(db: ^DB, query_str: string, args: []Value) -> (Result, Error) {
	conn, created_at, err := pool_acquire(db)
	if err != nil {return {}, err}
	defer pool_release(db, conn, created_at)
	return db.driver.exec(conn, query_str, args)
}

// Convenience query — the returned Rows owns the connection and
// releases it back to the pool on close_rows().
@(private)
db_query :: proc(db: ^DB, query_str: string, args: []Value) -> (Rows, Error) {
	conn, _, cerr := pool_acquire(db)
	if cerr != nil {return {}, cerr}

	handle, qerr := db.driver.query(conn, query_str, args)
	if qerr != nil {
		pool_release(db, conn, time.now())
		return {}, qerr
	}

	return Rows {
			db     = db, // non-nil = Rows owns the conn
			conn   = conn,
			handle = handle,
			driver = db.driver,
		}, nil
}

// --- Connection pool internals ---

// pool_acquire returns a connection handle and its creation time.
// The creation time must be passed back to pool_release to preserve
// accurate lifetime tracking.
@(private)
pool_acquire :: proc(db: ^DB) -> (Conn_Handle, time.Time, Error) {
	sync.mutex_lock(&db.mu)

	if db.closed {
		sync.mutex_unlock(&db.mu)
		return nil, {}, Pool_Error.Closed
	}

	now := time.now()

	// Try to reuse a pooled connection (LIFO — freshest first)
	for len(db.free_conns) > 0 {
		pc := pop(&db.free_conns)

		if db.max_lifetime > 0 && time.diff(pc.created_at, now) > db.max_lifetime {
			db.num_open -= 1
			sync.mutex_unlock(&db.mu)
			db.driver.close_conn(pc.handle)
			sync.mutex_lock(&db.mu)
			continue
		}

		sync.mutex_unlock(&db.mu)
		return pc.handle, pc.created_at, nil
	}

	if db.max_open > 0 && db.num_open >= db.max_open {
		sync.mutex_unlock(&db.mu)
		return nil, {}, Pool_Error.Exhausted
	}

	db.num_open += 1
	sync.mutex_unlock(&db.mu)

	handle, err := db.driver.open(db.driver.data, db.dsn, db.allocator)
	if err != nil {
		sync.mutex_lock(&db.mu)
		db.num_open -= 1
		sync.mutex_unlock(&db.mu)
		return nil, {}, err
	}

	return handle, now, nil
}

@(private)
pool_release :: proc(db: ^DB, conn: Conn_Handle, created_at: time.Time) {
	sync.mutex_lock(&db.mu)
	defer sync.mutex_unlock(&db.mu)

	if db.closed {
		db.num_open -= 1
		db.driver.close_conn(conn)
		return
	}

	if len(db.free_conns) < db.max_idle {
		append(&db.free_conns, Pool_Conn{handle = conn, created_at = created_at})
	} else {
		db.num_open -= 1
		db.driver.close_conn(conn)
	}
}

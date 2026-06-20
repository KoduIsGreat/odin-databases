package sql

import "core:time"

// Conn is an explicitly checked-out connection from the pool.
// The caller owns it and must return it with checkin().
// All operations on a Conn use its underlying connection directly —
// no pool interaction until checkin.
Conn :: struct {
	db:         ^DB,
	handle:     Conn_Handle,
	driver:     ^Driver,
	created_at: time.Time,
}

// checkout acquires a connection from the pool.
// The caller must call checkin() when done.
checkout :: proc(db: ^DB) -> (Conn, Error) {
	handle, created_at, err := pool_acquire(db)
	if err != nil {return {}, err}
	return Conn{db = db, handle = handle, driver = db.driver, created_at = created_at}, nil
}

// checkin returns a connection to the pool.
checkin :: proc(conn: ^Conn) -> Error {
	pool_release(conn.db, conn.handle, conn.created_at)
	conn^ = {} // zero out to prevent use-after-checkin
	return nil
}

@(private)
conn_exec :: proc(
	conn: ^Conn,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Result,
	Error,
) {
	result, err := conn.driver.exec(conn.handle, query_str, args)
	if err != nil {return {}, with_query(err, query_str, loc)}
	return result, nil
}

@(private)
conn_query :: proc(
	conn: ^Conn,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Rows,
	Error,
) {
	handle, err := conn.driver.query(conn.handle, query_str, args)
	if err != nil {return {}, with_query(err, query_str, loc)}

	// Rows from an explicit Conn do NOT release the connection.
	// The caller manages the Conn lifecycle separately.
	return Rows {
			db = nil,
			conn = conn.handle,
			handle = handle,
			driver = conn.driver,
			query = query_str,
			loc = loc,
		}, nil
}

// --- Advisory locking ---
//
// A session-scoped, application-defined lock for coordinating work (e.g. schema
// migrations) across processes. The lock is tied to this connection, so hold
// the same Conn for the duration and release with advisory_unlock on it. See
// the driver contract for details.

// supports_advisory_lock reports whether the connection's driver implements
// advisory locking. Callers that need cross-process coordination should branch
// on this rather than assuming a lock was taken.
supports_advisory_lock :: proc(conn: ^Conn) -> bool {
	return conn.driver.lock != nil && conn.driver.unlock != nil
}

// advisory_lock acquires the driver's advisory lock on this connection,
// blocking until it is granted. It is a no-op (returns nil) if the driver does
// not support locking — check supports_advisory_lock first if that distinction
// matters.
advisory_lock :: proc(conn: ^Conn, key: i64) -> Error {
	if conn.driver.lock == nil {return nil}
	return conn.driver.lock(conn.handle, key)
}

// advisory_unlock releases a lock previously taken with advisory_lock on the
// same connection. No-op (returns nil) if the driver does not support locking.
advisory_unlock :: proc(conn: ^Conn, key: i64) -> Error {
	if conn.driver.unlock == nil {return nil}
	return conn.driver.unlock(conn.handle, key)
}

// --- Cancellation ---
//
// interrupt aborts whatever statement is currently running on a connection,
// from another thread. It takes a DB + raw Conn_Handle (rather than a ^Conn)
// precisely because the connection is owned and in-use by a different thread —
// the worker running the query — while a watchdog/event-loop thread calls this
// to abort it. The interrupted call returns a Driver_Error. No-op if the driver
// does not support it (check supports_interrupt). See the driver contract.

// supports_interrupt reports whether the DB's driver can abort a running query.
supports_interrupt :: proc(db: ^DB) -> bool {
	return db.driver.interrupt != nil
}

// interrupt aborts any statement currently executing on handle. Safe to call
// from a thread other than the one running the statement. No-op if unsupported.
interrupt :: proc(db: ^DB, handle: Conn_Handle) {
	if db.driver.interrupt == nil {return}
	db.driver.interrupt(handle)
}

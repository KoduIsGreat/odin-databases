package sql

import "core:time"

// Tx is an in-progress transaction.
//
// If created via begin(db), the Tx owns a connection and returns it
// to the pool on commit/rollback. If created via begin(conn), the Tx
// borrows the caller's connection — commit/rollback end the transaction
// but the Conn remains checked out.
//
// All Rows and Stmts created from a Tx must be closed before
// commit or rollback.
//
// Error policy on commit/rollback: if the driver returns an error, the
// underlying connection may be in an inconsistent state and is *not*
// returned to the pool — it is closed instead (Go's database:sql does
// the same). Callers should treat the Tx as terminal.
Tx :: struct {
	db:          ^DB, // non-nil = owns the conn, release on commit/rollback
	conn_handle: Conn_Handle,
	tx_handle:   Tx_Handle,
	driver:      ^Driver,
	created_at:  time.Time, // preserved for pool_release lifetime tracking
	done:        bool,
}

// begin from the pool — checks out a connection, Tx owns it.
@(private)
db_begin :: proc(db: ^DB, opts := Tx_Options{}) -> (Tx, Error) {
	conn, created_at, cerr := pool_acquire(db)
	if cerr != nil {return {}, cerr}

	handle, terr := db.driver.begin(conn, opts)
	if terr != nil {
		pool_release(db, conn, created_at)
		return {}, terr
	}

	return Tx {
			db          = db, // non-nil = we own the conn
			conn_handle = conn,
			tx_handle   = handle,
			driver      = db.driver,
			created_at  = created_at,
		}, nil
}

// begin on an explicit Conn — Tx borrows it, caller still owns the Conn.
@(private)
conn_begin :: proc(conn: ^Conn, opts := Tx_Options{}) -> (Tx, Error) {
	handle, err := conn.driver.begin(conn.handle, opts)
	if err != nil {return {}, err}

	return Tx {
			db          = nil, // nil = we do NOT own the conn
			conn_handle = conn.handle,
			tx_handle   = handle,
			driver      = conn.driver,
			created_at  = conn.created_at,
		}, nil
}

@(private)
tx_exec :: proc(
	tx: ^Tx,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Result,
	Error,
) {
	if tx.done {
		return {}, with_query(
			Driver_Error{code = 0, message = "sql: transaction already completed"},
			query_str,
			loc,
		)
	}
	result, err := tx.driver.exec(tx.conn_handle, query_str, args)
	if err != nil {return {}, with_query(err, query_str, loc)}
	return result, nil
}

// Rows from a Tx do NOT own the connection — close them before
// commit/rollback.
@(private)
tx_query :: proc(
	tx: ^Tx,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> (
	Rows,
	Error,
) {
	if tx.done {
		return {}, with_query(
			Driver_Error{code = 0, message = "sql: transaction already completed"},
			query_str,
			loc,
		)
	}

	handle, err := tx.driver.query(tx.conn_handle, query_str, args)
	if err != nil {return {}, with_query(err, query_str, loc)}

	return Rows {
			db = nil,
			conn = tx.conn_handle,
			handle = handle,
			driver = tx.driver,
			query = query_str,
			loc = loc,
		}, nil
}

commit :: proc(tx: ^Tx) -> Error {
	if tx.done {
		return Driver_Error{code = 0, message = "sql: transaction already completed"}
	}
	tx.done = true
	err := tx.driver.tx_commit(tx.tx_handle)
	tx_release_conn(tx, err)
	return err
}

rollback :: proc(tx: ^Tx) -> Error {
	if tx.done {
		return Driver_Error{code = 0, message = "sql: transaction already completed"}
	}
	tx.done = true
	err := tx.driver.tx_rollback(tx.tx_handle)
	tx_release_conn(tx, err)
	return err
}

// tx_release_conn returns the connection to the pool on success, or
// discards it (closes it) on driver error. No-op when the Tx borrowed
// its connection from an explicit Conn (the caller still owns it).
@(private)
tx_release_conn :: proc(tx: ^Tx, err: Error) {
	if tx.db == nil {return}
	if err != nil {
		pool_discard(tx.db, tx.conn_handle)
	} else {
		pool_release(tx.db, tx.conn_handle, tx.created_at)
	}
}

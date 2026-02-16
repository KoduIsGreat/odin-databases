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
Tx :: struct {
	db:          ^DB, // non-nil = owns the conn, release on commit/rollback
	conn_handle: Conn_Handle,
	tx_handle:   Tx_Handle,
	driver:      ^Driver,
	done:        bool,
}

// begin from the pool — checks out a connection, Tx owns it.
@(private)
db_begin :: proc(db: ^DB, opts := Tx_Options{}) -> (Tx, Error) {
	conn, _, cerr := pool_acquire(db)
	if cerr != nil {return {}, cerr}

	handle, terr := db.driver.begin(conn, opts)
	if terr != nil {
		pool_release(db, conn, time.now())
		return {}, terr
	}

	return Tx {
			db          = db, // non-nil = we own the conn
			conn_handle = conn,
			tx_handle   = handle,
			driver      = db.driver,
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
		}, nil
}

@(private)
tx_exec :: proc(tx: ^Tx, query_str: string, args: []Value) -> (Result, Error) {
	if tx.done {
		return {}, Driver_Error{code = 0, message = "sql: transaction already completed"}
	}
	return tx.driver.exec(tx.conn_handle, query_str, args)
}

// Rows from a Tx do NOT own the connection — close them before
// commit/rollback.
@(private)
tx_query :: proc(tx: ^Tx, query_str: string, args: []Value) -> (Rows, Error) {
	if tx.done {
		return {}, Driver_Error{code = 0, message = "sql: transaction already completed"}
	}

	handle, err := tx.driver.query(tx.conn_handle, query_str, args)
	if err != nil {return {}, err}

	return Rows{db = nil, conn = tx.conn_handle, handle = handle, driver = tx.driver}, nil
}

commit :: proc(tx: ^Tx) -> Error {
	if tx.done {
		return Driver_Error{code = 0, message = "sql: transaction already completed"}
	}
	tx.done = true
	err := tx.driver.tx_commit(tx.tx_handle)
	if tx.db != nil {
		pool_release(tx.db, tx.conn_handle, {})
	}
	return err
}

rollback :: proc(tx: ^Tx) -> Error {
	if tx.done {
		return Driver_Error{code = 0, message = "sql: transaction already completed"}
	}
	tx.done = true
	err := tx.driver.tx_rollback(tx.tx_handle)
	if tx.db != nil {
		pool_release(tx.db, tx.conn_handle, {})
	}
	return err
}

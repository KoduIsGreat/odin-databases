package sql

import "core:time"

// query_row executes a query expected to return at most one row.
// It advances to the first row and eagerly releases the underlying
// connection back to the pool (via detach_rows). Any query error or
// "no rows" is stored in Row.err and surfaced when scan is called.
//
// Because the connection is released in query_row itself, there is
// no need for the caller to close the Row after scanning.
//
// Usage:
//   row := sql.query_row(db, "SELECT * FROM users WHERE id = ?", i64(1))
//   user: User
//   if err := sql.scan(&row, &user); err != nil { ... }

@(private)
db_query_row :: proc(db: ^DB, query_str: string, args: ..Value) -> Row {
	conn, _, cerr := pool_acquire(db)
	if cerr != nil {
		return Row{err = cerr, rows = {closed = true}}
	}

	handle, qerr := db.driver.query(conn, query_str, args)
	if qerr != nil {
		pool_release(db, conn, time.now())
		return Row{err = qerr, rows = {closed = true}}
	}

	row := Row {
		rows = {db = db, conn = conn, handle = handle, driver = db.driver},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return Row{err = Scan_Error.No_Row}
	}
	detach_rows(&row.rows)
	return row
}

@(private)
conn_query_row :: proc(conn: ^Conn, query_str: string, args: ..Value) -> Row {
	handle, qerr := conn.driver.query(conn.handle, query_str, args)
	if qerr != nil {
		return Row{err = qerr}
	}

	row := Row {
		rows = {db = nil, conn = conn.handle, handle = handle, driver = conn.driver},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return Row{err = Scan_Error.No_Row}
	}
	detach_rows(&row.rows)
	return row
}

@(private)
tx_query_row :: proc(tx: ^Tx, query_str: string, args: ..Value) -> Row {
	if tx.done {
		return Row {
			err = Driver_Error{code = 0, message = "sql: transaction already completed"},
		}
	}

	handle, qerr := tx.driver.query(tx.conn_handle, query_str, args)
	if qerr != nil {
		return Row{err = qerr}
	}

	row := Row {
		rows = {db = nil, conn = tx.conn_handle, handle = handle, driver = tx.driver},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return Row{err = Scan_Error.No_Row}
	}
	detach_rows(&row.rows)
	return row
}

// close_row is a no-op for detached rows (from query_row), since the
// connection is already released. Provided for symmetry if callers
// want a defer pattern. Safe to call on a Row with an error.
close_row :: proc(row: ^Row) -> Error {
	return close_rows(&row.rows)
}

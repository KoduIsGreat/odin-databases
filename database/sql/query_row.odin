package sql

import "core:time"

// query_row executes a query expected to return at most one row.
// It advances to the first row automatically. Any query error or
// "no rows" is stored in Row.err and surfaced when scan is called.
//
// scan on a Row automatically closes the underlying result set,
// so the caller does not need to close it manually.
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

// close_row closes the underlying result set and releases the connection
// if owned. Safe to call on a Row with an error (no-op).
close_row :: proc(row: ^Row) -> Error {
	return close_rows(&row.rows)
}

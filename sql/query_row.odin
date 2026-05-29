package sql

// query_row executes a query expected to return at most one row.
// It advances to the first row and eagerly releases the underlying
// connection back to the pool (via detach_rows). Any query error or
// "no rows" is stored in Row.err and surfaced when scan is called.
//
// Because the connection is released in query_row itself, there is
// no need for the caller to close the Row. close_row() is provided
// for symmetry and is safe to call on any Row — including error Rows
// where no driver handle was ever acquired.
//
// Usage:
//   row := sql.query_row(db, "SELECT * FROM users WHERE id = ?", i64(1))
//   user: User
//   if err := sql.scan(&row, &user); err != nil { ... }

@(private)
db_query_row :: proc(db: ^DB, query_str: string, args: ..Value) -> Row {
	conn, created_at, cerr := pool_acquire(db)
	if cerr != nil {
		return error_row(cerr)
	}

	handle, qerr := db.driver.query(conn, query_str, args)
	if qerr != nil {
		pool_release(db, conn, created_at)
		return error_row(qerr)
	}

	row := Row {
		rows = {
			db = db,
			conn = conn,
			handle = handle,
			driver = db.driver,
			created_at = created_at,
		},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return error_row(Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""})
	}
	detach_rows(&row.rows)
	return row
}

@(private)
conn_query_row :: proc(conn: ^Conn, query_str: string, args: ..Value) -> Row {
	handle, qerr := conn.driver.query(conn.handle, query_str, args)
	if qerr != nil {
		return error_row(qerr)
	}

	row := Row {
		rows = {db = nil, conn = conn.handle, handle = handle, driver = conn.driver},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return error_row(Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""})
	}
	detach_rows(&row.rows)
	return row
}

@(private)
tx_query_row :: proc(tx: ^Tx, query_str: string, args: ..Value) -> Row {
	if tx.done {
		return error_row(Driver_Error{code = 0, message = "sql: transaction already completed"})
	}

	handle, qerr := tx.driver.query(tx.conn_handle, query_str, args)
	if qerr != nil {
		return error_row(qerr)
	}

	row := Row {
		rows = {db = nil, conn = tx.conn_handle, handle = handle, driver = tx.driver},
	}
	if !next(&row.rows) {
		close_rows(&row.rows)
		return error_row(Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""})
	}
	detach_rows(&row.rows)
	return row
}

// error_row builds a Row whose embedded Rows is pre-closed, so callers
// can safely `defer sql.close_row(&row)` without a nil-driver crash.
@(private)
error_row :: #force_inline proc(err: Error) -> Row {
	return Row{err = err, rows = {closed = true}}
}

// close_row releases any remaining resources held by the Row. Safe on
// error Rows and on Rows whose connection has already been detached.
close_row :: proc(row: ^Row) -> Error {
	return close_rows(&row.rows)
}

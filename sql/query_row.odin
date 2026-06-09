package sql

import "base:runtime"

// query_row executes a query expected to return at most one row.
// It advances to the first row and eagerly releases the underlying
// connection back to the pool (via detach_rows). Any query error or
// "no rows" is stored in Row.err and surfaced when scan is called.
//
// The connection is released inside query_row, but the Row still buffers the
// detached column metadata and values, so the caller must close_row() to free
// them — use `defer sql.close_row(&row)`. close_row() is safe on any Row,
// including error Rows where no driver handle was ever acquired. Any string /
// []byte values moved out by scan() are owned by the scan destination and
// outlive close_row() (free them like any scanned value).
//
// Usage:
//   row := sql.query_row(db, "SELECT * FROM users WHERE id = ?", i64(1))
//   defer sql.close_row(&row)
//   user: User
//   if err := sql.scan(&row, &user); err != nil { ... }

@(private)
db_query_row :: proc(db: ^DB, query_str: string, args: ..Value, loc := #caller_location) -> Row {
	conn, created_at, cerr := pool_acquire(db)
	if cerr != nil {
		return error_row(cerr)
	}

	handle, qerr := db.driver.query(conn, query_str, args)
	if qerr != nil {
		pool_release(db, conn, created_at)
		return error_row(with_query(qerr, query_str, loc))
	}

	row := Row {
		rows = {
			db = db,
			conn = conn,
			handle = handle,
			driver = db.driver,
			created_at = created_at,
			query = query_str,
			loc = loc,
		},
	}
	if !next(&row.rows) {
		return error_row(first_row_error(&row.rows, query_str, loc))
	}
	detach_rows(&row.rows)
	return row
}

@(private)
conn_query_row :: proc(
	conn: ^Conn,
	query_str: string,
	args: ..Value,
	loc := #caller_location,
) -> Row {
	handle, qerr := conn.driver.query(conn.handle, query_str, args)
	if qerr != nil {
		return error_row(with_query(qerr, query_str, loc))
	}

	row := Row {
		rows = {
			db = nil,
			conn = conn.handle,
			handle = handle,
			driver = conn.driver,
			query = query_str,
			loc = loc,
		},
	}
	if !next(&row.rows) {
		return error_row(first_row_error(&row.rows, query_str, loc))
	}
	detach_rows(&row.rows)
	return row
}

@(private)
tx_query_row :: proc(tx: ^Tx, query_str: string, args: ..Value, loc := #caller_location) -> Row {
	if tx.done {
		return error_row(
			with_query(
				Driver_Error{code = 0, message = "sql: transaction already completed"},
				query_str,
				loc,
			),
		)
	}

	handle, qerr := tx.driver.query(tx.conn_handle, query_str, args)
	if qerr != nil {
		return error_row(with_query(qerr, query_str, loc))
	}

	row := Row {
		rows = {
			db = nil,
			conn = tx.conn_handle,
			handle = handle,
			driver = tx.driver,
			query = query_str,
			loc = loc,
		},
	}
	if !next(&row.rows) {
		return error_row(first_row_error(&row.rows, query_str, loc))
	}
	detach_rows(&row.rows)
	return row
}

// first_row_error closes a Rows whose first next() returned false and picks
// the error to store in the Row: a real mid-stream/driver error (already
// annotated by next()) wins over the generic "no rows" diagnosis.
@(private)
first_row_error :: proc(rows: ^Rows, query_str: string, loc: runtime.Source_Code_Location) -> Error {
	iter_err := rows.err
	rows_close(rows)
	if iter_err != nil {
		return iter_err
	}
	return with_query(Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""}, query_str, loc)
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
	return rows_close(&row.rows)
}

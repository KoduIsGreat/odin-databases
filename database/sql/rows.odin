package sql

// Rows is the result of a query.
//
// If created by a convenience db query, Rows owns the connection and
// releases it on close_rows(). If created from an explicit Conn or Tx,
// the caller manages the connection — close_rows() only closes the
// driver-level result set.
//
// Values read via next() have BORROWED semantics — they point into
// driver-owned memory and are only valid until the next next() call
// or close_rows(). Copy any string/[]byte you need to keep.
//
// Single-row pattern:
//   rows := sql.query(db, "SELECT ...", args)
//   defer sql.close_rows(&rows)
//   dest: [N]sql.Value
//   if sql.next(&rows, dest[:]) {
//       // use dest here — valid until close_rows
//   }
Rows :: struct {
	db:     ^DB,          // non-nil = owns the conn, release on close
	conn:   Conn_Handle,  // only used for pool release
	handle: Rows_Handle,
	driver: ^Driver,
	closed: bool,
}

// columns returns column metadata for the result set.
columns :: proc(rows: ^Rows) -> []Column {
	if rows.closed { return nil }
	return rows.driver.rows_columns(rows.handle)
}

// next advances to the next row and writes column values into dest.
// Returns false when no more rows remain.
// dest must have len >= number of columns.
//
// Values written to dest are BORROWED — valid only until the next
// call to next() or close_rows().
next :: proc(rows: ^Rows, dest: []Value) -> bool {
	if rows.closed { return false }
	return rows.driver.rows_next(rows.handle, dest)
}

// close_rows closes the result set. If the Rows owns a connection
// (from a convenience db query), it is returned to the pool.
close_rows :: proc(rows: ^Rows) -> Error {
	if rows.closed { return nil }
	rows.closed = true
	err := rows.driver.rows_close(rows.handle)
	if rows.db != nil {
		pool_release(rows.db, rows.conn, {})
	}
	return err
}

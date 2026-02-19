package sql

import "core:strings"

MAX_SCAN_COLS :: 64

// Rows is the result of a query. Call next() to advance to each row,
// then scan() to read column values.
//
// If created by a convenience db query, Rows owns the connection and
// releases it on close_rows(). If created from an explicit Conn or Tx,
// the caller manages the connection — close_rows() only closes the
// driver-level result set.
//
// next() buffers column values internally. These values are borrowed
// from the driver and valid only until the next call to next() or
// close_rows(). scan() clones string and []byte data using
// context.allocator so the scanned results outlive the Rows.
//
// Usage:
//   rows := sql.query(db, "SELECT ...", args)
//   defer sql.close_rows(&rows)
//   for sql.next(&rows) {
//       user: User
//       sql.scan(&rows, &user)
//   }
Rows :: struct {
	db:        ^DB, // non-nil = owns the conn, release on close
	conn:      Conn_Handle, // only used for pool release
	handle:    Rows_Handle,
	driver:    ^Driver,
	closed:    bool,

	// Current row state — filled by next()
	_values:    [MAX_SCAN_COLS]Value,
	_cols:      [MAX_SCAN_COLS]Column, // cached on first next()
	col_count:  int,
	has_row:    bool,
	_detached:  bool, // true = values are owned, scan should not clone
}

// Row holds the result of query_row(). The first row is already
// buffered and the connection has been released (detached). If the
// query failed or returned no rows, err is set and surfaced at scan
// time. Because the underlying resources are already released, there
// is no need to close a Row.
Row :: struct {
	err:  Error,
	rows: Rows,
}

// columns returns column metadata for the result set.
columns :: proc(rows: ^Rows) -> []Column {
	if rows.closed {return nil}
	return rows.driver.rows_columns(rows.handle)
}

// next advances to the next row. Returns false when no more rows remain.
// After next returns true, use scan() to read column values.
//
// Values are BORROWED — valid only until the next call to next() or
// close_rows().
next :: proc(rows: ^Rows) -> bool {
	if rows.closed {return false}
	if rows.col_count == 0 {
		cols := columns(rows)
		if cols == nil {return false}
		rows.col_count = len(cols)
		for i in 0 ..< rows.col_count {
			rows._cols[i] = cols[i]
		}
	}
	rows.has_row = rows.driver.rows_next(rows.handle, rows._values[:rows.col_count])
	return rows.has_row
}

// close_rows closes the result set. If the Rows owns a connection
// (from a convenience db query), it is returned to the pool.
close_rows :: proc(rows: ^Rows) -> Error {
	if rows.closed {return nil}
	rows.closed = true
	rows.has_row = false
	err := rows.driver.rows_close(rows.handle)
	if rows.db != nil {
		pool_release(rows.db, rows.conn, {})
	}
	return err
}

// detach_rows closes the driver result set and releases the connection,
// but preserves the buffered row values and has_row state. String and
// []byte values are cloned before the driver frees them. After detach,
// _detached is set so that scan() moves values directly instead of
// cloning again. Used by query_row to eagerly release resources.
@(private)
detach_rows :: proc(rows: ^Rows) -> Error {
	if rows.closed {return nil}
	// Clone borrowed data before close — driver frees it on rows_close.
	for i in 0 ..< rows.col_count {
		rows._cols[i].name = strings.clone(rows._cols[i].name)
		#partial switch &v in rows._values[i] {
		case string:
			v = strings.clone(v)
		case []byte:
			cloned := make([]byte, len(v))
			copy(cloned, v)
			v = cloned
		}
	}
	rows.closed = true
	rows._detached = true
	// has_row and _values intentionally preserved
	err := rows.driver.rows_close(rows.handle)
	if rows.db != nil {
		pool_release(rows.db, rows.conn, {})
	}
	return err
}

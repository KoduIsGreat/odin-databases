package sql

import "core:mem"
import "core:strings"
import "core:time"

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
//   if err := sql.rows_err(&rows); err != nil { /* result truncated mid-stream */ }
Rows :: struct {
	db:         ^DB, // non-nil = owns the conn, release on close
	conn:       Conn_Handle, // only used for pool release
	handle:     Rows_Handle,
	driver:     ^Driver,
	created_at: time.Time, // used by pool_release to preserve max_lifetime
	allocator:  mem.Allocator, // for _values / _cols
	closed:     bool,
	err:        Error, // set when next() stops; nil = clean EOF

	// Current row state — filled by next()
	col_count:  int,
	has_row:    bool,
	_detached:  bool, // true = values are owned, scan should not clone
	_values:    []Value,
	_cols:      []Column, // cached on first next()
}

// Row holds the result of query_row(). The first row is already
// buffered and the connection has been released (detached). If the
// query failed or returned no rows, err is set and surfaced at scan
// time. close_row() is safe whether the Row succeeded or carries
// an error — it is a no-op for detached/error Rows.
Row :: struct {
	err:  Error,
	rows: Rows,
}

// --- Codegen accessors ---
//
// These accessors exist so generated row-mapper code (see tools/scangen)
// in a *different package* can read the buffered row state without us
// exporting the underscore-prefixed fields. User code should normally
// use scan() / scan_row() instead.

row_value :: #force_inline proc(rows: ^Rows, i: int) -> Value {
	return rows._values[i]
}

row_col_name :: #force_inline proc(rows: ^Rows, i: int) -> string {
	return rows._cols[i].name
}

row_detached :: #force_inline proc(rows: ^Rows) -> bool {
	return rows._detached
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
	if rows._values == nil {
		cols := columns(rows)
		if cols == nil {return false}
		alloc := rows.allocator if rows.allocator.procedure != nil else context.allocator
		rows.allocator = alloc
		rows.col_count = len(cols)
		rows._values = make([]Value, rows.col_count, alloc)
		rows._cols = make([]Column, rows.col_count, alloc)
		for i in 0 ..< rows.col_count {
			rows._cols[i] = cols[i]
		}
	}
	rows.has_row = rows.driver.rows_next(rows.handle, rows._values)
	if !rows.has_row && rows.driver.rows_err != nil {
		rows.err = rows.driver.rows_err(rows.handle)
	}
	return rows.has_row
}

// rows_err returns the error that ended iteration early, or nil if the result
// set was fully consumed. Check it AFTER the next() loop — like Go's
// rows.Err() — because next() returns false for BOTH a clean end-of-rows and a
// mid-stream failure, and the two are otherwise indistinguishable:
//
//   for sql.next(&rows) { ... }
//   if err := sql.rows_err(&rows); err != nil { /* result was truncated */ }
rows_err :: proc(rows: ^Rows) -> Error {
	return rows.err
}

// close_rows closes the result set. If the Rows owns a connection
// (from a convenience db query), it is returned to the pool. Safe to
// call multiple times.
rows_close :: proc(rows: ^Rows) -> Error {
	if rows.closed {return nil}
	rows.closed = true
	rows.has_row = false

	err: Error
	if rows.driver != nil && rows.handle != nil {
		err = rows.driver.rows_close(rows.handle)
	}
	// A detached Row owns its cloned column-name strings (see detach_rows). For
	// a live Rows the names are borrowed from the driver, which frees them in
	// rows_close above, so only free them here when detached.
	if rows._detached {
		for i in 0 ..< len(rows._cols) {
			delete(rows._cols[i].name, rows.allocator)
		}
	}
	if rows._values != nil {
		delete(rows._values, rows.allocator)
		rows._values = nil
	}
	if rows._cols != nil {
		delete(rows._cols, rows.allocator)
		rows._cols = nil
	}
	if rows.db != nil {
		pool_release(rows.db, rows.conn, rows.created_at)
	}
	// A mid-stream iteration error is more useful than a close error, so it
	// wins. Callers that consumed the loop without calling rows_err() still
	// see it surfaced here.
	if rows.err != nil {return rows.err}
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
	// Clone borrowed data before close — the driver frees it on rows_close.
	// Column names are cloned with rows.allocator and freed by close_rows;
	// string/[]byte values are cloned with context.allocator so scan() can
	// move them into caller-owned memory (the caller frees them, exactly as
	// with a normal scan off a live Rows).
	for i in 0 ..< rows.col_count {
		rows._cols[i].name = strings.clone(rows._cols[i].name, rows.allocator)
		#partial switch &v in rows._values[i] {
		case string:
			v = strings.clone(v)
		case []byte:
			cloned := make([]byte, len(v))
			copy(cloned, v)
			v = cloned
		}
	}
	rows._detached = true
	// has_row and _values are intentionally preserved for the later scan.
	//
	// Release the driver result and connection now, then clear handle/db so
	// the eventual close_rows() frees the buffered values/columns exactly once
	// without re-closing the result or re-releasing the connection. (We do NOT
	// set rows.closed here — close_rows must still run to free the buffers.)
	err := rows.driver.rows_close(rows.handle)
	rows.handle = nil
	if rows.db != nil {
		pool_release(rows.db, rows.conn, rows.created_at)
		rows.db = nil
	}
	return err
}

package duckdb

import "core:strings"
import "core:time"

import sql "database:sql"
import drv "database:driver"
import ddb "database:bindings/duckdb/duckdb"

// Appender is DuckDB's bulk-insert fast path — far faster than row-by-row
// INSERT for loading many rows. Open one with appender() against a checked-out
// connection, push a value per column with append() (or append_row() for a
// whole row), end each row, then close():
//
//	conn, _ := sql.checkout(db)
//	defer sql.checkin(&conn)
//	app, _ := duck.appender(&conn, "trades")
//	for tr in trades {
//	    duck.append_row(&app, tr.id, tr.symbol, tr.price)
//	}
//	duck.appender_close(&app)   // flushes remaining rows
//
// The Appender targets a single table and borrows the connection for its
// lifetime (it does not own it — close the Appender, then check the conn back
// in). Values must be appended in column order; appender_close flushes any rows
// still buffered. Composite/DECIMAL/UUID values are not appendable here.
Appender :: struct {
	app:  ddb.Appender,
	conn: ^Duck_Conn,
}

// appender opens an Appender for `table` (optionally in `schema`, else the
// connection's default search path).
appender :: proc(conn: ^sql.Conn, table: string, schema := "") -> (Appender, sql.Error) {
	dc := cast(^Duck_Conn)conn.handle
	ctable := strings.clone_to_cstring(table, context.temp_allocator)
	cschema: cstring = nil
	if schema != "" {
		cschema = strings.clone_to_cstring(schema, context.temp_allocator)
	}
	a: ddb.Appender
	if ddb.appender_create(dc.con, cschema, ctable, &a) != .Success {
		err := make_error(dc, ddb.appender_error(a))
		ddb.appender_destroy(&a)
		return {}, err
	}
	return Appender{app = a, conn = dc}, nil
}

// append_value pushes a single column value into the current row. Mirrors the driver's
// parameter binding: bool, i64, i128 (HUGEINT), u128 (UHUGEINT), f64, string,
// []byte, time.Time (microsecond TIMESTAMP), and NULL.
append_value :: proc(a: ^Appender, value: sql.Value) -> sql.Error {
	st: ddb.State
	switch v in value {
	case bool:
		st = ddb.append_bool(a.app, v)
	case i64:
		st = ddb.append_int64(a.app, v)
	case i128:
		st = ddb.append_hugeint(a.app, transmute(ddb.Hugeint)v)
	case u128:
		st = ddb.append_uhugeint(a.app, transmute(ddb.Uhugeint)v)
	case f64:
		st = ddb.append_double(a.app, v)
	case string:
		st = ddb.append_varchar_length(a.app, as_cstring(v), ddb.Idx_T(len(v)))
	case []byte:
		st = ddb.append_blob(a.app, raw_data(v), ddb.Idx_T(len(v)))
	case time.Time:
		st = ddb.append_timestamp(a.app, ddb.Timestamp{micros = time.time_to_unix_nano(v) / 1000})
	case drv.Custom_Value:
		// Composite/DECIMAL/etc. aren't appendable; treat as NULL rather than fail.
		st = ddb.append_null(a.app)
	case drv.Null:
		st = ddb.append_null(a.app)
	}
	if st != .Success {
		return make_error(a.conn, ddb.appender_error(a.app))
	}
	return nil
}

// append_row appends a full row's worth of values (in column order) and ends the
// row. Stops at the first failing value.
append_row :: proc(a: ^Appender, values: ..sql.Value) -> sql.Error {
	for v in values {
		if err := append_value(a, v); err != nil {
			return err
		}
	}
	return end_row(a)
}

// append_default appends the column's DEFAULT value for the current position.
append_default :: proc(a: ^Appender) -> sql.Error {
	if ddb.append_default(a.app) != .Success {
		return make_error(a.conn, ddb.appender_error(a.app))
	}
	return nil
}

// end_row finishes the current row. The next append_value() starts a new row.
end_row :: proc(a: ^Appender) -> sql.Error {
	if ddb.appender_end_row(a.app) != .Success {
		return make_error(a.conn, ddb.appender_error(a.app))
	}
	return nil
}

// flush writes buffered rows to the table. Rows may also be flushed implicitly
// as the internal buffer fills; appender_close flushes whatever remains.
flush :: proc(a: ^Appender) -> sql.Error {
	if ddb.appender_flush(a.app) != .Success {
		return make_error(a.conn, ddb.appender_error(a.app))
	}
	return nil
}

// appender_close flushes any buffered rows and destroys the Appender. Returns an
// error from the final flush, if any. The Appender must not be used afterwards.
appender_close :: proc(a: ^Appender) -> sql.Error {
	err: sql.Error
	if ddb.appender_close(a.app) != .Success {
		err = make_error(a.conn, ddb.appender_error(a.app))
	}
	ddb.appender_destroy(&a.app)
	a.app = nil
	return err
}

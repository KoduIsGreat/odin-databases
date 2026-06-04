// Package duckdb is a preliminary DuckDB driver for `database:sql`. It wires
// the stable DuckDB C API (via `database:bindings/duckdb`) into the driver
// vtable: connection lifecycle, eager queries, prepared statements, and
// transactions.
//
// PRELIMINARY — what's intentionally not here yet:
//   - Streaming results. duckdb_query / execute_prepared materialize the whole
//     result; Rows iterate over that buffer. Large result sets are held fully
//     in memory.
//   - Per-cell reads use DuckDB's stable-but-"deprecated" value_* convenience
//     API rather than the faster data-chunk/vector API. Correct, just not the
//     fast path.
//   - Wide-integer (UBIGINT/HUGEINT) and exotic types are read through i64 or a
//     string fallback, so very large unsigned values can lose precision.
//   - last_insert_id is always 0 (DuckDB has no rowid/last-insert concept).
//   - Isolation levels are ignored: BEGIN starts DuckDB's snapshot-isolated tx.
//
// Connection model: each pooled connection opens its own DuckDB Database +
// Connection. As with the SQLite driver, that means a `:memory:` DSN gives each
// pooled connection an *isolated* in-memory database. For shared in-memory
// state across a pool, call `sql.set_max_open_conns(db, 1)` or use a file DSN.
package duckdb

import "core:mem"
import "core:strings"
import "core:time"

import drv "database:sql/driver"
import ddb "database:bindings/duckdb/duckdb"

// --- Driver vtable (public) ---

driver := drv.Driver {
	data         = nil,
	open         = duckdb_open,
	close_conn   = duckdb_close_conn,
	ping         = duckdb_ping,
	reset        = duckdb_reset_conn,
	exec         = duckdb_exec,
	query        = duckdb_query,
	prepare      = duckdb_prepare,
	stmt_exec    = duckdb_stmt_exec,
	stmt_query   = duckdb_stmt_query,
	stmt_close   = duckdb_stmt_close,
	stmt_reset   = duckdb_stmt_reset,
	rows_columns = duckdb_rows_columns,
	rows_next    = duckdb_rows_next,
	rows_close   = duckdb_rows_close,
	rows_err     = duckdb_rows_err,
	begin        = duckdb_begin,
	tx_commit    = duckdb_tx_commit,
	tx_rollback  = duckdb_tx_rollback,
}

// --- Internal wrapper types ---

Duck_Conn :: struct {
	db:        ddb.Database,
	con:       ddb.Connection,
	allocator: mem.Allocator,
	// Holds the most recent error message. DuckDB's error strings live inside
	// the result / prepared statement we destroy right away, so make_error
	// clones the message here (freeing the previous one). Like SQLite's errmsg,
	// a returned Driver_Error.message is borrowed and valid only until the next
	// failing call on this connection (or until the connection is closed).
	last_error: string,
}

Duck_Stmt :: struct {
	stmt: ddb.Prepared_Statement,
	conn: ^Duck_Conn,
}

Duck_Rows :: struct {
	res:       ddb.Result, // owned, materialized result (destroyed on close)
	conn:      ^Duck_Conn,
	cols:      []drv.Column, // allocated; names cloned into the same allocation block
	col_count: int,
	row_count: u64,
	cursor:    u64, // next row index to return
	// Per-row scratch: varchar/blob cells return malloc'd buffers we hand out as
	// borrowed values, then free on the next rows_next / on close.
	frees:     [dynamic]rawptr,
}

// --- Helpers ---

// make_error clones DuckDB's (about-to-be-freed) error string into the
// connection's last_error scratch and returns a Driver_Error borrowing it.
@(private)
make_error :: proc(conn: ^Duck_Conn, msg: cstring) -> drv.Error {
	if conn.last_error != "" {
		delete(conn.last_error, conn.allocator)
		conn.last_error = ""
	}
	if msg == nil {
		return drv.Driver_Error{code = 1, message = "duckdb: error"}
	}
	conn.last_error = strings.clone(string(msg), conn.allocator)
	return drv.Driver_Error{code = 1, message = conn.last_error}
}

@(private)
as_cstring :: #force_inline proc "contextless" (s: string) -> cstring {
	return transmute(cstring)raw_data(s)
}

// Bind positional args onto a prepared statement (1-based). Returns a
// Driver_Error for the first failing bind, or nil on success.
@(private)
bind_args :: proc(conn: ^Duck_Conn, stmt: ddb.Prepared_Statement, args: []drv.Value) -> drv.Error {
	for val, i in args {
		idx := ddb.Idx_T(i + 1)
		st: ddb.State
		switch v in val {
		case bool:
			st = ddb.bind_boolean(stmt, idx, v)
		case i64:
			st = ddb.bind_int64(stmt, idx, v)
		case f64:
			st = ddb.bind_double(stmt, idx, v)
		case string:
			st = ddb.bind_varchar_length(stmt, idx, as_cstring(v), ddb.Idx_T(len(v)))
		case []byte:
			st = ddb.bind_blob(stmt, idx, rawptr(raw_data(v)), ddb.Idx_T(len(v)))
		case time.Time:
			micros := time.time_to_unix_nano(v) / 1000
			st = ddb.bind_timestamp(stmt, idx, ddb.Timestamp{micros = micros})
		case drv.Null:
			st = ddb.bind_null(stmt, idx)
		case:
			st = ddb.bind_null(stmt, idx)
		}
		if st != .Success {
			return make_error(conn, ddb.prepare_error(stmt))
		}
	}
	return nil
}

// Map a DuckDB column type to the Odin type that best represents it.
@(private)
type_id_for :: proc(t: ddb.Type) -> typeid {
	#partial switch t {
	case .BOOLEAN:
		return typeid_of(bool)
	case .TINYINT, .SMALLINT, .INTEGER, .BIGINT,
	     .UTINYINT, .USMALLINT, .UINTEGER, .UBIGINT, .HUGEINT, .UHUGEINT:
		return typeid_of(i64)
	case .FLOAT, .DOUBLE:
		return typeid_of(f64)
	case .BLOB:
		return typeid_of([]byte)
	case .TIMESTAMP, .TIMESTAMP_S, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ,
	     .DATE, .TIME, .TIME_TZ:
		return typeid_of(time.Time)
	case:
		return typeid_of(string)
	}
}

// Read one cell into dest[i]. Strings/blobs are borrowed: their backing buffers
// are recorded in rows.frees and released on the next rows_next / close.
@(private)
read_value :: proc(rows: ^Duck_Rows, col: u64, row: u64, dest: ^drv.Value) {
	res := &rows.res
	if ddb.value_is_null(res, col, row) {
		dest^ = drv.Null{}
		return
	}

	switch ddb.column_type(res, col) {
	case .BOOLEAN:
		dest^ = ddb.value_boolean(res, col, row)
	case .TINYINT, .SMALLINT, .INTEGER, .BIGINT,
	     .UTINYINT, .USMALLINT, .UINTEGER, .UBIGINT, .HUGEINT, .UHUGEINT:
		dest^ = ddb.value_int64(res, col, row)
	case .FLOAT, .DOUBLE, .DECIMAL:
		dest^ = ddb.value_double(res, col, row)
	case .BLOB:
		b := ddb.value_blob(res, col, row)
		if b.data != nil {append(&rows.frees, b.data)}
		dest^ = (cast([^]byte)b.data)[:b.size]
	case .TIMESTAMP, .TIMESTAMP_S, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ:
		ts := ddb.value_timestamp(res, col, row)
		dest^ = time.Time{_nsec = ts.micros * 1000}
	case .DATE:
		d := ddb.value_date(res, col, row)
		dest^ = time.Time{_nsec = i64(d.days) * 86_400 * 1_000_000_000}
	case .TIME, .TIME_TZ:
		tm := ddb.value_time(res, col, row)
		dest^ = time.Time{_nsec = tm.micros * 1000}
	case .INVALID, .INTERVAL, .ENUM, .LIST, .STRUCT, .MAP, .ARRAY, .UUID,
	     .UNION, .BIT, .ANY, .VARINT, .SQLNULL, .VARCHAR:
		fallthrough
	case:
		// VARCHAR and everything we don't model explicitly: take DuckDB's string
		// rendering. value_varchar hands back a malloc'd copy we must free.
		c := ddb.value_varchar(res, col, row)
		if c != nil {append(&rows.frees, rawptr(c))}
		dest^ = string(c)
	}
}

// Build a Rows from an owned, materialized result.
@(private)
make_rows :: proc(conn: ^Duck_Conn, res: ddb.Result) -> ^Duck_Rows {
	rows := new(Duck_Rows, conn.allocator)
	rows.res = res
	rows.conn = conn
	rows.col_count = int(ddb.column_count(&rows.res))
	rows.row_count = ddb.row_count(&rows.res)
	rows.cursor = 0
	rows.frees = make([dynamic]rawptr, conn.allocator)

	cols := make([]drv.Column, rows.col_count, conn.allocator)
	for i in 0 ..< rows.col_count {
		ci := ddb.Idx_T(i)
		// column_name's buffer is owned by the result; clone so it outlives it
		// (and so close can free the result while Column names stay valid).
		name := strings.clone(string(ddb.column_name(&rows.res, ci)), conn.allocator)
		cols[i] = drv.Column {
			name     = name,
			type_id  = type_id_for(ddb.column_type(&rows.res, ci)),
			nullable = true,
		}
	}
	rows.cols = cols
	return rows
}

@(private)
free_pending :: proc(rows: ^Duck_Rows) {
	for p in rows.frees {
		ddb.free(p)
	}
	clear(&rows.frees)
}

// --- Connection lifecycle ---

@(private)
duckdb_open :: proc(
	driver_data: rawptr,
	dsn: string,
	allocator: mem.Allocator,
) -> (
	drv.Conn_Handle,
	drv.Error,
) {
	cdsn := strings.clone_to_cstring(dsn, allocator)
	defer mem.free(rawptr(cdsn), allocator)

	db: ddb.Database
	if ddb.open(cdsn, &db) != .Success {
		return nil, drv.Driver_Error{code = 1, message = "duckdb: failed to open database"}
	}

	con: ddb.Connection
	if ddb.connect(db, &con) != .Success {
		ddb.close(&db)
		return nil, drv.Driver_Error{code = 1, message = "duckdb: failed to connect"}
	}

	conn := new(Duck_Conn, allocator)
	conn.db = db
	conn.con = con
	conn.allocator = allocator
	return drv.Conn_Handle(conn), nil
}

@(private)
duckdb_close_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Duck_Conn)handle
	ddb.disconnect(&conn.con)
	ddb.close(&conn.db)
	if conn.last_error != "" {delete(conn.last_error, conn.allocator)}
	mem.free(conn, conn.allocator)
	return nil
}

@(private)
duckdb_ping :: proc(handle: drv.Conn_Handle) -> drv.Error {return nil}

@(private)
duckdb_reset_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {return nil}

// --- Direct exec / query ---

// run a parameterless query string and destroy the result, returning rows_affected.
@(private)
exec_simple :: proc(conn: ^Duck_Conn, query_str: string) -> (drv.Result, drv.Error) {
	cq := strings.clone_to_cstring(query_str, conn.allocator)
	defer mem.free(rawptr(cq), conn.allocator)

	res: ddb.Result
	if ddb.query(conn.con, cq, &res) != .Success {
		err := make_error(conn, ddb.result_error(&res))
		ddb.destroy_result(&res)
		return {}, err
	}
	affected := i64(ddb.rows_changed(&res))
	ddb.destroy_result(&res)
	return drv.Result{last_insert_id = 0, rows_affected = affected}, nil
}

@(private)
duckdb_exec :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	drv.Result,
	drv.Error,
) {
	conn := cast(^Duck_Conn)handle

	// Parameterless: duckdb_query runs every ';'-separated statement (DDL /
	// migration scripts), reporting the final statement's result.
	if len(args) == 0 {
		return exec_simple(conn, query_str)
	}

	stmt, perr := prepare_stmt(conn, query_str)
	if perr != nil {return {}, perr}
	defer ddb.destroy_prepare(&stmt)

	if berr := bind_args(conn, stmt, args); berr != nil {return {}, berr}

	res: ddb.Result
	if ddb.execute_prepared(stmt, &res) != .Success {
		err := make_error(conn, ddb.result_error(&res))
		ddb.destroy_result(&res)
		return {}, err
	}
	affected := i64(ddb.rows_changed(&res))
	ddb.destroy_result(&res)
	return drv.Result{last_insert_id = 0, rows_affected = affected}, nil
}

@(private)
duckdb_query :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	drv.Rows_Handle,
	drv.Error,
) {
	conn := cast(^Duck_Conn)handle

	res: ddb.Result
	if len(args) == 0 {
		cq := strings.clone_to_cstring(query_str, conn.allocator)
		defer mem.free(rawptr(cq), conn.allocator)
		if ddb.query(conn.con, cq, &res) != .Success {
			err := make_error(conn, ddb.result_error(&res))
			ddb.destroy_result(&res)
			return nil, err
		}
	} else {
		stmt, perr := prepare_stmt(conn, query_str)
		if perr != nil {return nil, perr}
		defer ddb.destroy_prepare(&stmt)

		if berr := bind_args(conn, stmt, args); berr != nil {return nil, berr}

		if ddb.execute_prepared(stmt, &res) != .Success {
			err := make_error(conn, ddb.result_error(&res))
			ddb.destroy_result(&res)
			return nil, err
		}
	}

	return drv.Rows_Handle(make_rows(conn, res)), nil
}

// --- Prepared statements ---

// prepare_stmt compiles a query, mapping a prepare failure to a Driver_Error.
@(private)
prepare_stmt :: proc(
	conn: ^Duck_Conn,
	query_str: string,
) -> (
	ddb.Prepared_Statement,
	drv.Error,
) {
	cq := strings.clone_to_cstring(query_str, conn.allocator)
	defer mem.free(rawptr(cq), conn.allocator)

	stmt: ddb.Prepared_Statement
	if ddb.prepare(conn.con, cq, &stmt) != .Success {
		err := make_error(conn, ddb.prepare_error(stmt))
		ddb.destroy_prepare(&stmt)
		return nil, err
	}
	return stmt, nil
}

@(private)
duckdb_prepare :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
) -> (
	drv.Stmt_Handle,
	drv.Error,
) {
	conn := cast(^Duck_Conn)handle
	stmt, err := prepare_stmt(conn, query_str)
	if err != nil {return nil, err}

	wrapper := new(Duck_Stmt, conn.allocator)
	wrapper.stmt = stmt
	wrapper.conn = conn
	return drv.Stmt_Handle(wrapper), nil
}

@(private)
duckdb_stmt_exec :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (drv.Result, drv.Error) {
	wrapper := cast(^Duck_Stmt)handle
	if berr := bind_args(wrapper.conn, wrapper.stmt, args); berr != nil {return {}, berr}

	res: ddb.Result
	if ddb.execute_prepared(wrapper.stmt, &res) != .Success {
		err := make_error(wrapper.conn, ddb.result_error(&res))
		ddb.destroy_result(&res)
		return {}, err
	}
	affected := i64(ddb.rows_changed(&res))
	ddb.destroy_result(&res)
	return drv.Result{last_insert_id = 0, rows_affected = affected}, nil
}

@(private)
duckdb_stmt_query :: proc(
	handle: drv.Stmt_Handle,
	args: []drv.Value,
) -> (
	drv.Rows_Handle,
	drv.Error,
) {
	wrapper := cast(^Duck_Stmt)handle
	if berr := bind_args(wrapper.conn, wrapper.stmt, args); berr != nil {return nil, berr}

	res: ddb.Result
	if ddb.execute_prepared(wrapper.stmt, &res) != .Success {
		err := make_error(wrapper.conn, ddb.result_error(&res))
		ddb.destroy_result(&res)
		return nil, err
	}
	// The result is fully materialized and independent of the statement, so the
	// prepared statement stays reusable while these Rows are iterated.
	return drv.Rows_Handle(make_rows(wrapper.conn, res)), nil
}

@(private)
duckdb_stmt_close :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	wrapper := cast(^Duck_Stmt)handle
	ddb.destroy_prepare(&wrapper.stmt)
	mem.free(wrapper, wrapper.conn.allocator)
	return nil
}

@(private)
duckdb_stmt_reset :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	// DuckDB has no separate "reset" — re-binding overwrites parameters.
	return nil
}

// --- Rows ---

@(private)
duckdb_rows_columns :: proc(handle: drv.Rows_Handle) -> []drv.Column {
	return (cast(^Duck_Rows)handle).cols
}

@(private)
duckdb_rows_next :: proc(handle: drv.Rows_Handle, dest: []drv.Value) -> bool {
	rows := cast(^Duck_Rows)handle
	free_pending(rows) // release the previous row's borrowed buffers
	if rows.cursor >= rows.row_count {return false}

	row := rows.cursor
	n := min(len(dest), rows.col_count)
	for i in 0 ..< n {
		read_value(rows, u64(i), row, &dest[i])
	}
	rows.cursor += 1
	return true
}

@(private)
duckdb_rows_err :: proc(handle: drv.Rows_Handle) -> drv.Error {
	// Results are materialized up-front: a query either fails at query() time or
	// yields a complete buffer, so there's no mid-stream error to surface.
	return nil
}

@(private)
duckdb_rows_close :: proc(handle: drv.Rows_Handle) -> drv.Error {
	rows := cast(^Duck_Rows)handle
	alloc := rows.conn.allocator

	free_pending(rows)
	delete(rows.frees)
	for c in rows.cols {
		delete(c.name, alloc)
	}
	delete(rows.cols, alloc)
	ddb.destroy_result(&rows.res)
	mem.free(rows, alloc)
	return nil
}

// --- Transactions ---

@(private)
duckdb_begin :: proc(handle: drv.Conn_Handle, opts: drv.Tx_Options) -> (drv.Tx_Handle, drv.Error) {
	conn := cast(^Duck_Conn)handle
	// DuckDB uses snapshot isolation; isolation level / read_only are ignored.
	if _, err := exec_simple(conn, "BEGIN TRANSACTION"); err != nil {
		return nil, err
	}
	return drv.Tx_Handle(conn), nil
}

@(private)
duckdb_tx_commit :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Duck_Conn)handle
	_, err := exec_simple(conn, "COMMIT")
	return err
}

@(private)
duckdb_tx_rollback :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Duck_Conn)handle
	_, err := exec_simple(conn, "ROLLBACK")
	return err
}

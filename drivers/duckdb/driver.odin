// Package duckdb is a preliminary DuckDB driver for `database:sql`. It wires
// the stable DuckDB C API (via `database:bindings/duckdb`) into the driver
// vtable: connection lifecycle, eager queries, prepared statements, and
// transactions.
//
// Reads go through DuckDB's modern data-chunk/vector API (duckdb_fetch_chunk):
// per-column vector pointers are cached once per chunk, so the hot path does no
// per-cell metadata lookups and no per-cell allocation. Wide integers map
// losslessly (HUGEINT/UBIGINT -> i128, UHUGEINT -> u128) and DECIMAL is exact
// via a Custom_Value (scan into string for the exact text, f64 for convenience,
// or i128 for the unscaled value).
//
// PRELIMINARY — what's intentionally not here yet:
//   - Streaming results. duckdb_query / execute_prepared materialize the whole
//     result; fetch_chunk then walks that buffer. Large result sets are held
//     fully in memory (a future streaming exec would reuse this same reader).
//   - Composite/exotic types (LIST, STRUCT, MAP, ARRAY, ENUM, UUID, INTERVAL,
//     BIT, VARINT, UNION) are not modeled: a column of such a type can be
//     queried, but scanning it fails with a type mismatch rather than silently
//     returning an approximate string. Structured support will reuse the same
//     Custom_Value mechanism DECIMAL uses.
//   - last_insert_id is always 0 (DuckDB has no rowid/last-insert concept).
//   - Isolation levels are ignored: BEGIN starts DuckDB's snapshot-isolated tx.
//
// Connection model: each pooled connection opens its own DuckDB Database +
// Connection. As with the SQLite driver, that means a `:memory:` DSN gives each
// pooled connection an *isolated* in-memory database. For shared in-memory
// state across a pool, call `sql.set_max_open_conns(db, 1)` or use a file DSN.
package duckdb

import "core:fmt"
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

	// Per-column schema, cached once at make_rows so the hot read path performs
	// no per-cell metadata lookups.
	col_types: []ddb.Type, // DuckDB type id per column
	dec_scale: []u8, // DECIMAL scale per column (0 otherwise)
	dec_itype: []ddb.Type, // DECIMAL physical storage type per column

	// Current data chunk plus the per-column vector data/validity pointers into
	// it. Read via the modern duckdb_fetch_chunk path — no per-cell value_* calls
	// and no per-cell malloc. Borrowed string/blob cells point directly into
	// `chunk` and stay valid until the next chunk is fetched (i.e. until the
	// rows_next that crosses a chunk boundary), satisfying the driver's
	// borrowed-value contract (valid until the next rows_next / rows_close).
	chunk:      ddb.Data_Chunk,
	chunk_size: u64,
	chunk_row:  u64, // next row index within the current chunk
	vdata:      []rawptr, // vector_get_data per column, for the current chunk
	vvalid:     []^u64, // vector_get_validity per column, for the current chunk
	done:       bool,
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
		case i128:
			// Hugeint is {lower: u64, upper: i64} — a little-endian 128-bit
			// two's-complement integer, layout-identical to i128.
			st = ddb.bind_hugeint(stmt, idx, transmute(ddb.Hugeint)v)
		case u128:
			st = ddb.bind_uhugeint(stmt, idx, transmute(ddb.Uhugeint)v)
		case f64:
			st = ddb.bind_double(stmt, idx, v)
		case string:
			st = ddb.bind_varchar_length(stmt, idx, as_cstring(v), ddb.Idx_T(len(v)))
		case []byte:
			st = ddb.bind_blob(stmt, idx, rawptr(raw_data(v)), ddb.Idx_T(len(v)))
		case time.Time:
			micros := time.time_to_unix_nano(v) / 1000
			st = ddb.bind_timestamp(stmt, idx, ddb.Timestamp{micros = micros})
		case drv.Custom_Value:
			// Custom_Value is a read-side carrier (e.g. DECIMAL cells); it isn't a
			// meaningful query parameter. Bind a DECIMAL via a string + CAST.
			st = ddb.bind_null(stmt, idx)
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
	case .TINYINT, .SMALLINT, .INTEGER, .BIGINT, .UTINYINT, .USMALLINT, .UINTEGER:
		return typeid_of(i64)
	case .UBIGINT, .HUGEINT:
		// u64 and i128 both exceed i64's range; i128 holds either without loss.
		return typeid_of(i128)
	case .UHUGEINT:
		return typeid_of(u128)
	case .FLOAT, .DOUBLE:
		return typeid_of(f64)
	case .DECIMAL:
		// Best-effort representative type. The value arrives as a Custom_Value;
		// scan into f64 (convenient, lossy) or string (exact).
		return typeid_of(f64)
	case .BLOB:
		return typeid_of([]byte)
	case .TIMESTAMP, .TIMESTAMP_S, .TIMESTAMP_MS, .TIMESTAMP_NS, .TIMESTAMP_TZ,
	     .DATE, .TIME, .TIME_TZ:
		return typeid_of(time.Time)
	case .VARCHAR:
		return typeid_of(string)
	case:
		// Unmodeled composite/exotic types (LIST/STRUCT/ENUM/UUID/...). The value
		// is an unsupported Custom_Value; report string as the nominal type.
		return typeid_of(string)
	}
}

// --- DECIMAL support (exact, via Custom_Value) ---

// Decimal_Payload is packed into a Custom_Value's inline storage: the unscaled
// 128-bit value plus the decimal scale (value / 10^scale is the real number).
@(private)
Decimal_Payload :: struct {
	value: i128,
	scale: u8,
}
#assert(size_of(Decimal_Payload) <= size_of(drv.Custom_Value{}.storage))

// Read a DECIMAL's unscaled integer from a vector, widening its physical storage
// (int16/int32/int64/int128, chosen by width) to i128.
@(private)
decimal_raw :: proc(itype: ddb.Type, data: rawptr, row: u64) -> i128 {
	#partial switch itype {
	case .SMALLINT:
		return i128(([^]i16)(data)[row])
	case .INTEGER:
		return i128(([^]i32)(data)[row])
	case .BIGINT:
		return i128(([^]i64)(data)[row])
	case .HUGEINT:
		return ([^]i128)(data)[row]
	case:
		return 0
	}
}

@(private)
make_decimal_cell :: proc(value: i128, scale: u8) -> drv.Custom_Value {
	cv: drv.Custom_Value
	p := (^Decimal_Payload)(&cv.storage)
	p.value = value
	p.scale = scale
	cv.convert = decimal_convert
	return cv
}

@(private)
decimal_convert :: proc(
	payload: rawptr,
	dest_type: typeid,
	dest: rawptr,
	allocator: mem.Allocator,
) -> bool {
	p := (^Decimal_Payload)(payload)
	switch dest_type {
	case f64:
		r := f64(p.value)
		for _ in 0 ..< p.scale {r /= 10}
		(^f64)(dest)^ = r
	case i128:
		// The unscaled integer (caller knows the scale from the schema).
		(^i128)(dest)^ = p.value
	case i64:
		div: i128 = 1
		for _ in 0 ..< p.scale {div *= 10}
		(^i64)(dest)^ = i64(p.value / div)
	case string:
		(^string)(dest)^ = decimal_to_string(p.value, p.scale, allocator)
	case:
		return false
	}
	return true
}

// Format an unscaled value + scale as exact decimal text, e.g. (12345, 2) ->
// "123.45", (5, 4) -> "0.0005". |value| < 10^38 < 2^127, so negation is safe.
@(private)
decimal_to_string :: proc(value: i128, scale: u8, allocator: mem.Allocator) -> string {
	if scale == 0 {
		return fmt.aprintf("%d", value, allocator = allocator)
	}
	neg := value < 0
	mag := value if !neg else -value
	digits := fmt.tprintf("%d", mag) // magnitude in the temp allocator
	sc := int(scale)

	b := strings.builder_make(allocator)
	if neg {strings.write_byte(&b, '-')}
	if len(digits) <= sc {
		strings.write_string(&b, "0.")
		for _ in 0 ..< (sc - len(digits)) {strings.write_byte(&b, '0')}
		strings.write_string(&b, digits)
	} else {
		split := len(digits) - sc
		strings.write_string(&b, digits[:split])
		strings.write_byte(&b, '.')
		strings.write_string(&b, digits[split:])
	}
	return strings.to_string(b)
}

// --- Unmodeled exotic types ---

// unsupported_cell marks a column type we don't model yet (LIST/STRUCT/ENUM/...).
// Scanning it fails with a clean type mismatch instead of silently corrupting or
// dropping the value. The DuckDB type is stashed for potential diagnostics.
@(private)
unsupported_cell :: proc(t: ddb.Type) -> drv.Custom_Value {
	cv: drv.Custom_Value
	(^ddb.Type)(&cv.storage)^ = t
	cv.convert = unsupported_convert
	return cv
}

@(private)
unsupported_convert :: proc(_: rawptr, _: typeid, _: rawptr, _: mem.Allocator) -> bool {
	return false
}

// --- Vector cell reader ---

// duck_string borrows a VARCHAR/BLOB string_t's bytes directly from the chunk
// (no copy). Valid until the next chunk is fetched; scan() clones it.
@(private)
duck_string :: proc(st: ^ddb.String_T) -> string {
	n := int(ddb.string_t_length(st^))
	p := ddb.string_t_data(st)
	return string(([^]u8)(p)[:n])
}

// Read one cell (column `col`, row-within-chunk `row`) into dest from the cached
// vector pointers for the current chunk.
@(private)
read_cell :: proc(rows: ^Duck_Rows, col: int, row: u64, dest: ^drv.Value) {
	if v := rows.vvalid[col]; v != nil && !ddb.validity_row_is_valid(v, ddb.Idx_T(row)) {
		dest^ = drv.Null{}
		return
	}
	data := rows.vdata[col]
	switch rows.col_types[col] {
	case .BOOLEAN:
		dest^ = ([^]bool)(data)[row]
	case .TINYINT:
		dest^ = i64(([^]i8)(data)[row])
	case .SMALLINT:
		dest^ = i64(([^]i16)(data)[row])
	case .INTEGER:
		dest^ = i64(([^]i32)(data)[row])
	case .BIGINT:
		dest^ = ([^]i64)(data)[row]
	case .UTINYINT:
		dest^ = i64(([^]u8)(data)[row])
	case .USMALLINT:
		dest^ = i64(([^]u16)(data)[row])
	case .UINTEGER:
		dest^ = i64(([^]u32)(data)[row])
	case .UBIGINT:
		dest^ = i128(([^]u64)(data)[row])
	case .HUGEINT:
		dest^ = ([^]i128)(data)[row]
	case .UHUGEINT:
		dest^ = ([^]u128)(data)[row]
	case .FLOAT:
		dest^ = f64(([^]f32)(data)[row])
	case .DOUBLE:
		dest^ = ([^]f64)(data)[row]
	case .DECIMAL:
		dest^ = make_decimal_cell(decimal_raw(rows.dec_itype[col], data, row), rows.dec_scale[col])
	case .VARCHAR:
		dest^ = duck_string(&([^]ddb.String_T)(data)[row])
	case .BLOB:
		st := &([^]ddb.String_T)(data)[row]
		n := int(ddb.string_t_length(st^))
		dest^ = (([^]byte)(ddb.string_t_data(st)))[:n]
	case .TIMESTAMP, .TIMESTAMP_TZ:
		// micros since epoch (TIMESTAMP_TZ stores the UTC instant).
		dest^ = time.Time{_nsec = ([^]i64)(data)[row] * 1000}
	case .TIMESTAMP_S:
		dest^ = time.Time{_nsec = ([^]i64)(data)[row] * 1_000_000_000}
	case .TIMESTAMP_MS:
		dest^ = time.Time{_nsec = ([^]i64)(data)[row] * 1_000_000}
	case .TIMESTAMP_NS:
		dest^ = time.Time{_nsec = ([^]i64)(data)[row]}
	case .DATE:
		dest^ = time.Time{_nsec = i64(([^]i32)(data)[row]) * 86_400 * 1_000_000_000}
	case .TIME:
		// micros since midnight.
		dest^ = time.Time{_nsec = ([^]i64)(data)[row] * 1000}
	case .TIME_TZ:
		// Packed 40-bit micros + 24-bit offset; normalize to the UTC instant.
		s := ddb.from_time_tz(([^]ddb.Time_Tz)(data)[row])
		day_us :=
			(i64(s.time.hour) * 3600 + i64(s.time.min) * 60 + i64(s.time.sec)) * 1_000_000 +
			i64(s.time.micros)
		dest^ = time.Time{_nsec = (day_us - i64(s.offset) * 1_000_000) * 1000}
	case .INVALID, .INTERVAL, .ENUM, .LIST, .STRUCT, .MAP, .ARRAY, .UUID, .UNION, .BIT,
	     .ANY, .VARINT, .SQLNULL:
		dest^ = unsupported_cell(rows.col_types[col])
	case:
		dest^ = unsupported_cell(rows.col_types[col])
	}
}

// Build a Rows from an owned, materialized result, caching per-column schema.
@(private)
make_rows :: proc(conn: ^Duck_Conn, res: ddb.Result) -> ^Duck_Rows {
	a := conn.allocator
	rows := new(Duck_Rows, a)
	rows.res = res
	rows.conn = conn
	rows.col_count = int(ddb.column_count(&rows.res))

	rows.cols = make([]drv.Column, rows.col_count, a)
	rows.col_types = make([]ddb.Type, rows.col_count, a)
	rows.dec_scale = make([]u8, rows.col_count, a)
	rows.dec_itype = make([]ddb.Type, rows.col_count, a)
	rows.vdata = make([]rawptr, rows.col_count, a)
	rows.vvalid = make([]^u64, rows.col_count, a)

	for i in 0 ..< rows.col_count {
		ci := ddb.Idx_T(i)
		t := ddb.column_type(&rows.res, ci)
		rows.col_types[i] = t
		if t == .DECIMAL {
			lt := ddb.column_logical_type(&rows.res, ci)
			rows.dec_scale[i] = ddb.decimal_scale(lt)
			rows.dec_itype[i] = ddb.decimal_internal_type(lt)
			ddb.destroy_logical_type(&lt)
		}
		// column_name's buffer is owned by the result; clone so it outlives it
		// (and so close can free the result while Column names stay valid).
		name := strings.clone(string(ddb.column_name(&rows.res, ci)), a)
		rows.cols[i] = drv.Column {
			name     = name,
			type_id  = type_id_for(t),
			nullable = true,
		}
	}
	return rows
}

// load_next_chunk destroys the current chunk and fetches the next, caching each
// column's vector data/validity pointers. Returns false at end of result.
@(private)
load_next_chunk :: proc(rows: ^Duck_Rows) -> bool {
	if rows.chunk != nil {
		ddb.destroy_data_chunk(&rows.chunk)
		rows.chunk = nil
	}
	c := ddb.fetch_chunk(rows.res)
	if c == nil {
		return false
	}
	sz := u64(ddb.data_chunk_get_size(c))
	if sz == 0 {
		ddb.destroy_data_chunk(&c)
		return false
	}
	rows.chunk = c
	rows.chunk_size = sz
	rows.chunk_row = 0
	for i in 0 ..< rows.col_count {
		v := ddb.data_chunk_get_vector(c, ddb.Idx_T(i))
		rows.vdata[i] = ddb.vector_get_data(v)
		rows.vvalid[i] = ddb.vector_get_validity(v)
	}
	return true
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
	if rows.done {return false}
	// Advance to the next chunk when the current one is exhausted (this also
	// frees the previous chunk, invalidating its borrowed string/blob cells —
	// the borrowed-value contract only promises validity until this call).
	if rows.chunk == nil || rows.chunk_row >= rows.chunk_size {
		if !load_next_chunk(rows) {
			rows.done = true
			return false
		}
	}

	row := rows.chunk_row
	n := min(len(dest), rows.col_count)
	for i in 0 ..< n {
		read_cell(rows, i, row, &dest[i])
	}
	rows.chunk_row += 1
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
	a := rows.conn.allocator

	if rows.chunk != nil {ddb.destroy_data_chunk(&rows.chunk)}
	for c in rows.cols {
		delete(c.name, a)
	}
	delete(rows.cols, a)
	delete(rows.col_types, a)
	delete(rows.dec_scale, a)
	delete(rows.dec_itype, a)
	delete(rows.vdata, a)
	delete(rows.vvalid, a)
	ddb.destroy_result(&rows.res)
	mem.free(rows, a)
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

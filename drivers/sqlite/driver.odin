package sqlite

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import drv "../../database/sql/driver"
import sql3 "../../bindings/sqlite/sqlite"

// --- Driver vtable (public) ---

driver := drv.Driver {
	data         = nil,
	open         = sqlite_open,
	close_conn   = sqlite_close_conn,
	ping         = sqlite_ping,
	reset        = sqlite_reset_conn,
	exec         = sqlite_exec,
	query        = sqlite_query,
	prepare      = sqlite_prepare,
	stmt_exec    = sqlite_stmt_exec,
	stmt_query   = sqlite_stmt_query,
	stmt_close   = sqlite_stmt_close,
	stmt_reset   = sqlite_stmt_reset,
	rows_columns = sqlite_rows_columns,
	rows_next    = sqlite_rows_next,
	rows_close   = sqlite_rows_close,
	begin        = sqlite_begin,
	tx_commit    = sqlite_tx_commit,
	tx_rollback  = sqlite_tx_rollback,
}

// --- Internal wrapper types ---

Sqlite_Conn :: struct {
	db:        ^sql3.sqlite3,
	allocator: mem.Allocator,
}

Sqlite_Stmt :: struct {
	stmt: ^sql3.stmt,
	conn: ^Sqlite_Conn,
}

Sqlite_Rows :: struct {
	stmt:      ^sql3.stmt,
	conn:      ^Sqlite_Conn,
	col_count: int,
	cols:      []drv.Column, // borrowed names, allocated slice
	owns_stmt: bool, // true = finalize on close, false = reset on close
	done:      bool, // true = step already returned DONE
}

// --- Helpers ---

@(private)
make_error :: proc(db: ^sql3.sqlite3) -> drv.Error {
	return drv.Driver_Error{code = int(sql3.errcode(db)), message = string(sql3.errmsg(db))}
}

// SQLite's bind_text/prepare_v2 take a (cstring, nByte) pair. SQLite uses
// nByte to determine the buffer length and does NOT require null termination
// when nByte >= 0. We therefore reinterpret the string's data pointer as a
// cstring and pass the explicit length. Safe because SQLite never reads past
// nByte bytes.
@(private)
as_cstring :: #force_inline proc "contextless" (s: string) -> cstring {
	return transmute(cstring)raw_data(s)
}

@(private)
bind_args :: proc(stmt: ^sql3.stmt, args: []drv.Value) -> i32 {
	for val, i in args {
		idx := i32(i + 1) // SQLite bind is 1-indexed
		rc: i32
		#partial switch v in val {
		case bool:
			rc = sql3.bind_int64(stmt, idx, 1 if v else 0)
		case i64:
			rc = sql3.bind_int64(stmt, idx, v)
		case f64:
			rc = sql3.bind_double(stmt, idx, v)
		case string:
			rc = sql3.bind_text(stmt, idx, as_cstring(v), i32(len(v)), sql3.TRANSIENT)
		case []byte:
			rc = sql3.bind_blob(stmt, idx, rawptr(raw_data(v)), i32(len(v)), sql3.TRANSIENT)
		case time.Time:
			// Format as ISO-8601 TEXT: "YYYY-MM-DD HH:MM:SS"
			buf: [19]u8
			yr, mo, dy := time.date(v)
			hr, mn, sc := time.clock(v)
			s := fmt.bprintf(buf[:], "%4d-%02d-%02d %02d:%02d:%02d", yr, int(mo), dy, hr, mn, sc)
			rc = sql3.bind_text(stmt, idx, as_cstring(s), i32(len(s)), sql3.TRANSIENT)
		case drv.Null:
			rc = sql3.bind_null(stmt, idx)
		case:
			rc = sql3.bind_null(stmt, idx)
		}
		if rc != sql3.OK {return rc}
	}
	return sql3.OK
}

@(private)
read_values :: proc(stmt: ^sql3.stmt, dest: []drv.Value, cols: []drv.Column) {
	for i in 0 ..< len(cols) {
		col := i32(i)
		is_time := cols[i].type_id == typeid_of(time.Time)

		switch sql3.column_type(stmt, col) {
		case sql3.INTEGER:
			if is_time {
				// Unix epoch seconds → time.Time
				unix_sec := sql3.column_int64(stmt, col)
				dest[i] = time.Time {
					_nsec = unix_sec * i64(1e9),
				}
			} else {
				dest[i] = sql3.column_int64(stmt, col)
			}
		case sql3.FLOAT:
			dest[i] = sql3.column_double(stmt, col)
		case sql3.TEXT:
			ptr := sql3.column_text(stmt, col)
			nbytes := sql3.column_bytes(stmt, col)
			s := string((cast([^]u8)ptr)[:nbytes])
			if is_time {
				if t, ok := parse_datetime(s); ok {
					dest[i] = t
				} else {
					dest[i] = s // fall back to string
				}
			} else {
				dest[i] = s
			}
		case sql3.BLOB:
			ptr := sql3.column_blob(stmt, col)
			nbytes := sql3.column_bytes(stmt, col)
			dest[i] = (cast([^]byte)ptr)[:nbytes]
		case sql3.NULL:
			dest[i] = drv.Null{}
		}
	}
}

// Parse "YYYY-MM-DD HH:MM:SS" into time.Time. Minimal parser — no timezone.
@(private)
parse_datetime :: proc(s: string) -> (t: time.Time, ok: bool) {
	if len(s) < 19 {return {}, false}
	if s[4] != '-' || s[7] != '-' || s[13] != ':' || s[16] != ':' {return {}, false}
	if s[10] != ' ' && s[10] != 'T' {return {}, false}

	year := parse_int(s[0:4]) or_return
	month := parse_int(s[5:7]) or_return
	day := parse_int(s[8:10]) or_return
	hour := parse_int(s[11:13]) or_return
	min := parse_int(s[14:16]) or_return
	sec := parse_int(s[17:19]) or_return

	return time.datetime_to_time(i64(year), i64(month), i64(day), i64(hour), i64(min), i64(sec))
}

@(private)
parse_int :: proc(s: string) -> (int, bool) {
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' {return 0, false}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

// Build column metadata. Names are borrowed from SQLite (valid until
// the statement is finalized or reset). The slice itself is allocated
// with the given allocator and must be freed on rows close.
@(private)
build_columns :: proc(
	stmt: ^sql3.stmt,
	col_count: int,
	allocator: mem.Allocator,
) -> []drv.Column {
	cols := make([]drv.Column, col_count, allocator)
	for i in 0 ..< col_count {
		col := i32(i)
		tid: typeid
		decltype := sql3.column_decltype(stmt, col)
		if decltype != nil && is_datetime_decltype(string(decltype)) {
			tid = typeid_of(time.Time)
		}
		cols[i] = drv.Column {
			name     = string(sql3.column_name(stmt, col)),
			type_id  = tid,
			nullable = true,
		}
	}
	return cols
}

// Check if a SQLite declared type name indicates a datetime column.
// Matches: DATETIME, DATE, TIMESTAMP, TIME, and common variations.
@(private)
is_datetime_decltype :: proc(decltype: string) -> bool {
	upper: [32]u8
	n := min(len(decltype), 32)
	for i in 0 ..< n {
		ch := decltype[i]
		upper[i] = ch - 32 if ch >= 'a' && ch <= 'z' else ch
	}
	s := string(upper[:n])
	return s == "DATETIME" || s == "TIMESTAMP" || s == "DATE" || s == "TIME"
}

// --- Connection lifecycle ---

@(private)
sqlite_open :: proc(
	driver_data: rawptr,
	dsn: string,
	allocator: mem.Allocator,
) -> (
	drv.Conn_Handle,
	drv.Error,
) {
	cdsn := strings.clone_to_cstring(dsn, allocator)
	defer mem.free(rawptr(cdsn), allocator)

	db: ^sql3.sqlite3
	rc := sql3.open(cdsn, &db)
	if rc != sql3.OK {
		return nil, drv.Driver_Error{code = int(rc), message = "sqlite: failed to open"}
	}

	conn := new(Sqlite_Conn, allocator)
	conn.db = db
	conn.allocator = allocator
	return drv.Conn_Handle(conn), nil
}

@(private)
sqlite_close_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := sql3.close(conn.db)
	alloc := conn.allocator
	mem.free(conn, alloc)
	if rc != sql3.OK {
		return drv.Driver_Error{code = int(rc), message = "sqlite: close failed"}
	}
	return nil
}

@(private)
sqlite_ping :: proc(handle: drv.Conn_Handle) -> drv.Error {
	return nil
}

@(private)
sqlite_reset_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	return nil
}

// --- Direct exec / query ---

@(private)
sqlite_exec :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	drv.Result,
	drv.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sql3.stmt
	rc := sql3.prepare_v2(conn.db, as_cstring(query_str), i32(len(query_str)), &stmt, nil)
	if rc != sql3.OK {
		return {}, make_error(conn.db)
	}
	defer sql3.finalize(stmt)

	if bind_args(stmt, args) != sql3.OK {
		return {}, make_error(conn.db)
	}

	rc = sql3.step(stmt)
	if rc != sql3.DONE && rc != sql3.ROW {
		return {}, make_error(conn.db)
	}

	return drv.Result {
			last_insert_id = sql3.last_insert_rowid(conn.db),
			rows_affected = i64(sql3.changes(conn.db)),
		},
		nil
}

@(private)
sqlite_query :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	drv.Rows_Handle,
	drv.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sql3.stmt
	rc := sql3.prepare_v2(conn.db, as_cstring(query_str), i32(len(query_str)), &stmt, nil)
	if rc != sql3.OK {
		return nil, make_error(conn.db)
	}

	if bind_args(stmt, args) != sql3.OK {
		sql3.finalize(stmt)
		return nil, make_error(conn.db)
	}

	ncols := int(sql3.column_count(stmt))
	rows := new(Sqlite_Rows, conn.allocator)
	rows.stmt = stmt
	rows.conn = conn
	rows.col_count = ncols
	rows.cols = build_columns(stmt, ncols, conn.allocator)
	rows.owns_stmt = true
	return drv.Rows_Handle(rows), nil
}

// --- Prepared statements ---

@(private)
sqlite_prepare :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
) -> (
	drv.Stmt_Handle,
	drv.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sql3.stmt
	rc := sql3.prepare_v2(conn.db, as_cstring(query_str), i32(len(query_str)), &stmt, nil)
	if rc != sql3.OK {
		return nil, make_error(conn.db)
	}

	wrapper := new(Sqlite_Stmt, conn.allocator)
	wrapper.stmt = stmt
	wrapper.conn = conn
	return drv.Stmt_Handle(wrapper), nil
}

@(private)
sqlite_stmt_exec :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (drv.Result, drv.Error) {
	wrapper := cast(^Sqlite_Stmt)handle

	if bind_args(wrapper.stmt, args) != sql3.OK {
		return {}, make_error(wrapper.conn.db)
	}

	rc := sql3.step(wrapper.stmt)
	if rc != sql3.DONE && rc != sql3.ROW {
		return {}, make_error(wrapper.conn.db)
	}

	return drv.Result {
			last_insert_id = sql3.last_insert_rowid(wrapper.conn.db),
			rows_affected = i64(sql3.changes(wrapper.conn.db)),
		},
		nil
}

@(private)
sqlite_stmt_query :: proc(
	handle: drv.Stmt_Handle,
	args: []drv.Value,
) -> (
	drv.Rows_Handle,
	drv.Error,
) {
	wrapper := cast(^Sqlite_Stmt)handle

	if bind_args(wrapper.stmt, args) != sql3.OK {
		return nil, make_error(wrapper.conn.db)
	}

	ncols := int(sql3.column_count(wrapper.stmt))
	rows := new(Sqlite_Rows, wrapper.conn.allocator)
	rows.stmt = wrapper.stmt
	rows.conn = wrapper.conn
	rows.col_count = ncols
	rows.cols = build_columns(wrapper.stmt, ncols, wrapper.conn.allocator)
	rows.owns_stmt = false // prepared stmt → reset on close, don't finalize
	return drv.Rows_Handle(rows), nil
}

@(private)
sqlite_stmt_close :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	wrapper := cast(^Sqlite_Stmt)handle
	rc := sql3.finalize(wrapper.stmt)
	mem.free(wrapper, wrapper.conn.allocator)
	if rc != sql3.OK {
		return drv.Driver_Error{code = int(rc), message = "sqlite: finalize failed"}
	}
	return nil
}

@(private)
sqlite_stmt_reset :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	wrapper := cast(^Sqlite_Stmt)handle
	rc := sql3.reset(wrapper.stmt)
	if rc != sql3.OK {
		return make_error(wrapper.conn.db)
	}
	return nil
}

// --- Rows ---

@(private)
sqlite_rows_columns :: proc(handle: drv.Rows_Handle) -> []drv.Column {
	rows := cast(^Sqlite_Rows)handle
	return rows.cols
}

@(private)
sqlite_rows_next :: proc(handle: drv.Rows_Handle, dest: []drv.Value) -> bool {
	rows := cast(^Sqlite_Rows)handle
	if rows.done {return false}

	rc := sql3.step(rows.stmt)
	if rc == sql3.ROW {
		read_values(rows.stmt, dest, rows.cols)
		return true
	}

	rows.done = true
	return false
}

@(private)
sqlite_rows_close :: proc(handle: drv.Rows_Handle) -> drv.Error {
	rows := cast(^Sqlite_Rows)handle

	rc: i32
	if rows.owns_stmt {
		rc = sql3.finalize(rows.stmt)
	} else {
		rc = sql3.reset(rows.stmt)
	}

	alloc := rows.conn.allocator
	delete(rows.cols, alloc)
	mem.free(rows, alloc)

	if rc != sql3.OK {
		return drv.Driver_Error{code = int(rc), message = "sqlite: rows close failed"}
	}
	return nil
}

// --- Transactions ---

@(private)
sqlite_begin :: proc(handle: drv.Conn_Handle, opts: drv.Tx_Options) -> (drv.Tx_Handle, drv.Error) {
	conn := cast(^Sqlite_Conn)handle

	begin_sql: cstring
	switch opts.isolation {
	case .Serializable:
		begin_sql = "BEGIN EXCLUSIVE"
	case .Read_Committed, .Repeatable_Read:
		begin_sql = "BEGIN IMMEDIATE"
	case .Default, .Read_Uncommitted:
		begin_sql = "BEGIN"
	}

	rc := sql3.exec(conn.db, begin_sql, nil, nil, nil)
	if rc != sql3.OK {
		return nil, make_error(conn.db)
	}

	return drv.Tx_Handle(conn), nil
}

@(private)
sqlite_tx_commit :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := sql3.exec(conn.db, "COMMIT", nil, nil, nil)
	if rc != sql3.OK {
		return make_error(conn.db)
	}
	return nil
}

@(private)
sqlite_tx_rollback :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := sql3.exec(conn.db, "ROLLBACK", nil, nil, nil)
	if rc != sql3.OK {
		return make_error(conn.db)
	}
	return nil
}

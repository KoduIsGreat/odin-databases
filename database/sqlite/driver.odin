package sqlite

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import sql "../../database/sql"

// --- Driver vtable (public) ---

driver := sql.Driver {
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
	db:        ^sqlite3,
	allocator: mem.Allocator,
}

Sqlite_Stmt :: struct {
	stmt: ^sqlite3_stmt,
	conn: ^Sqlite_Conn,
}

Sqlite_Rows :: struct {
	stmt:      ^sqlite3_stmt,
	conn:      ^Sqlite_Conn,
	col_count: int,
	cols:      []sql.Column, // borrowed names, allocated slice
	owns_stmt: bool, // true = finalize on close, false = reset on close
	done:      bool, // true = step already returned DONE
}

// --- Helpers ---

@(private)
make_error :: proc(db: ^sqlite3) -> sql.Error {
	return sql.Driver_Error{code = int(errcode(db)), message = string(errmsg(db))}
}

@(private)
bind_args :: proc(stmt: ^sqlite3_stmt, args: []sql.Value) -> c.int {
	for val, i in args {
		idx := c.int(i + 1) // SQLite bind is 1-indexed
		rc: c.int
		#partial switch v in val {
		case bool:
			rc = bind_int64(stmt, idx, 1 if v else 0)
		case i64:
			rc = bind_int64(stmt, idx, v)
		case f64:
			rc = bind_double(stmt, idx, v)
		case string:
			rc = bind_text(stmt, idx, raw_data(v), c.int(len(v)), SQLITE_TRANSIENT)
		case []byte:
			rc = bind_blob(stmt, idx, raw_data(v), c.int(len(v)), SQLITE_TRANSIENT)
		case time.Time:
			// Format as ISO-8601 TEXT: "YYYY-MM-DD HH:MM:SS"
			buf: [19]u8
			yr, mo, dy := time.date(v)
			hr, mn, sc := time.clock(v)
			s := fmt.bprintf(buf[:], "%4d-%02d-%02d %02d:%02d:%02d", yr, int(mo), dy, hr, mn, sc)
			rc = bind_text(stmt, idx, raw_data(s), c.int(len(s)), SQLITE_TRANSIENT)
		case sql.Null:
			rc = bind_null(stmt, idx)
		case:
			rc = bind_null(stmt, idx)
		}
		if rc != SQLITE_OK {return rc}
	}
	return SQLITE_OK
}

@(private)
read_values :: proc(stmt: ^sqlite3_stmt, dest: []sql.Value, cols: []sql.Column) {
	for i in 0 ..< len(cols) {
		col := c.int(i)
		is_time := cols[i].type_id == typeid_of(time.Time)

		switch column_type(stmt, col) {
		case SQLITE_INTEGER:
			if is_time {
				// Unix epoch seconds → time.Time
				unix_sec := column_int64(stmt, col)
				t, ok := time.datetime_to_time(1970, 1, 1, 0, 0, 0)
				if ok {
					dest[i] = time.Time {
						_nsec = unix_sec * i64(1e9),
					}
				} else {
					dest[i] = unix_sec
				}
			} else {
				dest[i] = column_int64(stmt, col)
			}
		case SQLITE_FLOAT:
			dest[i] = column_double(stmt, col)
		case SQLITE_TEXT:
			ptr := column_text(stmt, col)
			nbytes := column_bytes(stmt, col)
			s := string(ptr[:nbytes])
			if is_time {
				if t, ok := parse_datetime(s); ok {
					dest[i] = t
				} else {
					dest[i] = s // fall back to string
				}
			} else {
				dest[i] = s
			}
		case SQLITE_BLOB:
			ptr := column_blob(stmt, col)
			nbytes := column_bytes(stmt, col)
			dest[i] = (cast([^]byte)ptr)[:nbytes]
		case SQLITE_NULL:
			dest[i] = sql.Null{}
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
	stmt: ^sqlite3_stmt,
	col_count: int,
	allocator: mem.Allocator,
) -> []sql.Column {
	cols := make([]sql.Column, col_count, allocator)
	for i in 0 ..< col_count {
		col := c.int(i)
		tid: typeid
		decltype := column_decltype(stmt, col)
		if decltype != nil && is_datetime_decltype(string(decltype)) {
			tid = typeid_of(time.Time)
		}
		cols[i] = sql.Column {
			name     = string(column_name(stmt, col)),
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
	// Case-insensitive check for common datetime type names
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
	sql.Conn_Handle,
	sql.Error,
) {
	cdsn := strings.clone_to_cstring(dsn, allocator)
	defer mem.free(rawptr(cdsn), allocator)

	db: ^sqlite3
	rc := open(cdsn, &db)
	if rc != SQLITE_OK {
		return nil, sql.Driver_Error{code = int(rc), message = "sqlite: failed to open"}
	}

	conn := new(Sqlite_Conn, allocator)
	conn.db = db
	conn.allocator = allocator
	return sql.Conn_Handle(conn), nil
}

@(private)
sqlite_close_conn :: proc(handle: sql.Conn_Handle) -> sql.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := close(conn.db)
	alloc := conn.allocator
	mem.free(conn, alloc)
	if rc != SQLITE_OK {
		return sql.Driver_Error{code = int(rc), message = "sqlite: close failed"}
	}
	return nil
}

@(private)
sqlite_ping :: proc(handle: sql.Conn_Handle) -> sql.Error {
	return nil
}

@(private)
sqlite_reset_conn :: proc(handle: sql.Conn_Handle) -> sql.Error {
	return nil
}

// --- Direct exec / query ---

@(private)
sqlite_exec :: proc(
	handle: sql.Conn_Handle,
	query_str: string,
	args: []sql.Value,
) -> (
	sql.Result,
	sql.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sqlite3_stmt
	rc := prepare_v2(conn.db, raw_data(query_str), c.int(len(query_str)), &stmt, nil)
	if rc != SQLITE_OK {
		return {}, make_error(conn.db)
	}
	defer finalize(stmt)

	if bind_args(stmt, args) != SQLITE_OK {
		return {}, make_error(conn.db)
	}

	rc = step(stmt)
	if rc != SQLITE_DONE && rc != SQLITE_ROW {
		return {}, make_error(conn.db)
	}

	return sql.Result {
			last_insert_id = last_insert_rowid(conn.db),
			rows_affected = i64(changes(conn.db)),
		},
		nil
}

@(private)
sqlite_query :: proc(
	handle: sql.Conn_Handle,
	query_str: string,
	args: []sql.Value,
) -> (
	sql.Rows_Handle,
	sql.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sqlite3_stmt
	rc := prepare_v2(conn.db, raw_data(query_str), c.int(len(query_str)), &stmt, nil)
	if rc != SQLITE_OK {
		return nil, make_error(conn.db)
	}

	if bind_args(stmt, args) != SQLITE_OK {
		finalize(stmt)
		return nil, make_error(conn.db)
	}

	ncols := int(column_count(stmt))
	rows := new(Sqlite_Rows, conn.allocator)
	rows.stmt = stmt
	rows.conn = conn
	rows.col_count = ncols
	rows.cols = build_columns(stmt, ncols, conn.allocator)
	rows.owns_stmt = true
	return sql.Rows_Handle(rows), nil
}

// --- Prepared statements ---

@(private)
sqlite_prepare :: proc(
	handle: sql.Conn_Handle,
	query_str: string,
) -> (
	sql.Stmt_Handle,
	sql.Error,
) {
	conn := cast(^Sqlite_Conn)handle

	stmt: ^sqlite3_stmt
	rc := prepare_v2(conn.db, raw_data(query_str), c.int(len(query_str)), &stmt, nil)
	if rc != SQLITE_OK {
		return nil, make_error(conn.db)
	}

	wrapper := new(Sqlite_Stmt, conn.allocator)
	wrapper.stmt = stmt
	wrapper.conn = conn
	return sql.Stmt_Handle(wrapper), nil
}

@(private)
sqlite_stmt_exec :: proc(handle: sql.Stmt_Handle, args: []sql.Value) -> (sql.Result, sql.Error) {
	wrapper := cast(^Sqlite_Stmt)handle

	if bind_args(wrapper.stmt, args) != SQLITE_OK {
		return {}, make_error(wrapper.conn.db)
	}

	rc := step(wrapper.stmt)
	if rc != SQLITE_DONE && rc != SQLITE_ROW {
		return {}, make_error(wrapper.conn.db)
	}

	return sql.Result {
			last_insert_id = last_insert_rowid(wrapper.conn.db),
			rows_affected = i64(changes(wrapper.conn.db)),
		},
		nil
}

@(private)
sqlite_stmt_query :: proc(
	handle: sql.Stmt_Handle,
	args: []sql.Value,
) -> (
	sql.Rows_Handle,
	sql.Error,
) {
	wrapper := cast(^Sqlite_Stmt)handle

	if bind_args(wrapper.stmt, args) != SQLITE_OK {
		return nil, make_error(wrapper.conn.db)
	}

	ncols := int(column_count(wrapper.stmt))
	rows := new(Sqlite_Rows, wrapper.conn.allocator)
	rows.stmt = wrapper.stmt
	rows.conn = wrapper.conn
	rows.col_count = ncols
	rows.cols = build_columns(wrapper.stmt, ncols, wrapper.conn.allocator)
	rows.owns_stmt = false // prepared stmt → reset on close, don't finalize
	return sql.Rows_Handle(rows), nil
}

@(private)
sqlite_stmt_close :: proc(handle: sql.Stmt_Handle) -> sql.Error {
	wrapper := cast(^Sqlite_Stmt)handle
	rc := finalize(wrapper.stmt)
	mem.free(wrapper, wrapper.conn.allocator)
	if rc != SQLITE_OK {
		return sql.Driver_Error{code = int(rc), message = "sqlite: finalize failed"}
	}
	return nil
}

@(private)
sqlite_stmt_reset :: proc(handle: sql.Stmt_Handle) -> sql.Error {
	wrapper := cast(^Sqlite_Stmt)handle
	rc := reset(wrapper.stmt)
	if rc != SQLITE_OK {
		return make_error(wrapper.conn.db)
	}
	return nil
}

// --- Rows ---

@(private)
sqlite_rows_columns :: proc(handle: sql.Rows_Handle) -> []sql.Column {
	rows := cast(^Sqlite_Rows)handle
	return rows.cols
}

@(private)
sqlite_rows_next :: proc(handle: sql.Rows_Handle, dest: []sql.Value) -> bool {
	rows := cast(^Sqlite_Rows)handle
	if rows.done {return false}

	rc := step(rows.stmt)
	if rc == SQLITE_ROW {
		read_values(rows.stmt, dest, rows.cols)
		return true
	}

	rows.done = true
	return false
}

@(private)
sqlite_rows_close :: proc(handle: sql.Rows_Handle) -> sql.Error {
	rows := cast(^Sqlite_Rows)handle

	rc: c.int
	if rows.owns_stmt {
		rc = finalize(rows.stmt)
	} else {
		rc = reset(rows.stmt)
	}

	alloc := rows.conn.allocator
	delete(rows.cols, alloc)
	mem.free(rows, alloc)

	if rc != SQLITE_OK {
		return sql.Driver_Error{code = int(rc), message = "sqlite: rows close failed"}
	}
	return nil
}

// --- Transactions ---

@(private)
sqlite_begin :: proc(handle: sql.Conn_Handle, opts: sql.Tx_Options) -> (sql.Tx_Handle, sql.Error) {
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

	rc := exec(conn.db, begin_sql, nil, nil, nil)
	if rc != SQLITE_OK {
		return nil, make_error(conn.db)
	}

	return sql.Tx_Handle(conn), nil
}

@(private)
sqlite_tx_commit :: proc(handle: sql.Tx_Handle) -> sql.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := exec(conn.db, "COMMIT", nil, nil, nil)
	if rc != SQLITE_OK {
		return make_error(conn.db)
	}
	return nil
}

@(private)
sqlite_tx_rollback :: proc(handle: sql.Tx_Handle) -> sql.Error {
	conn := cast(^Sqlite_Conn)handle
	rc := exec(conn.db, "ROLLBACK", nil, nil, nil)
	if rc != SQLITE_OK {
		return make_error(conn.db)
	}
	return nil
}

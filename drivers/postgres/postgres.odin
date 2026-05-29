// database:drivers/postgres — a pure-Odin PostgreSQL driver implementing the
// `database:sql/driver` contract over the v3 frontend/backend wire protocol
// (no libpq). It speaks directly to a server over a TCP socket via core:net.
//
// Status / scope (v1):
//   - Authentication: trust, cleartext, MD5, and SCRAM-SHA-256 (the default).
//   - TLS is NOT yet implemented — connect with sslmode=disable (or to a local
//     / self-hosted server that allows plaintext). sslmode=require / verify-*
//     return an error until an OpenSSL-backed transport is added.
//   - Parameters and results use the TEXT wire format. `?` placeholders are
//     translated to `$1, $2, ...`; native `$n` also works.
//   - Streaming rows: values are decoded per-DataRow and borrow the connection
//     read buffer, matching the driver contract's borrowed-value semantics
//     (sql.scan clones what it keeps).
//
// Usage mirrors every other driver — pass &postgres.driver to sql.open:
//
//   import sql "database:sql"
//   import pg  "database:drivers/postgres"
//
//   db, err := sql.open(&pg.driver, "postgres://user:pass@localhost:5432/mydb?sslmode=disable")
//
// The DSN accepts a URL (postgres:// or postgresql://) or libpq-style
// keyword/value pairs ("host=localhost port=5432 user=u dbname=d sslmode=disable").
//
// Note: PostgreSQL does not report a last-insert id without RETURNING, so
// Result.last_insert_id is always 0; Result.rows_affected comes from the
// CommandComplete tag. Use `RETURNING id` + query_row to read generated keys.
package postgres

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"

import drv "database:sql/driver"

// --- Driver vtable (public) ---

driver := drv.Driver {
	data         = nil,
	open         = pg_open,
	close_conn   = pg_close_conn,
	ping         = pg_ping,
	reset        = pg_reset_conn,
	exec         = pg_exec,
	query        = pg_query,
	prepare      = pg_prepare,
	stmt_exec    = pg_stmt_exec,
	stmt_query   = pg_stmt_query,
	stmt_close   = pg_stmt_close,
	stmt_reset   = pg_stmt_reset,
	rows_columns = pg_rows_columns,
	rows_next    = pg_rows_next,
	rows_close   = pg_rows_close,
	begin        = pg_begin,
	tx_commit    = pg_tx_commit,
	tx_rollback  = pg_tx_rollback,
}

// --- Internal wrapper types ---

@(private)
Pg_Conn :: struct {
	socket:       net.TCP_Socket,
	allocator:    mem.Allocator,
	rbuf:         [dynamic]u8, // last-read message payload (reused; values borrow it)
	wbuf:         [dynamic]u8, // outgoing message scratch (reused)
	last_error:   string, // owned; replaced per error, valid until the next one
	stmt_counter: int,
	tx_status:    u8, // last ReadyForQuery status ('I' idle, 'T' in tx, 'E' failed)
}

@(private)
Pg_Stmt :: struct {
	conn: ^Pg_Conn,
	name: string, // server-side prepared statement name (owned)
}

@(private)
Pg_Rows :: struct {
	conn: ^Pg_Conn,
	cols: []drv.Column, // owned (names cloned out of the read buffer)
	done: bool, // true once CommandComplete/ReadyForQuery seen
}

// --- Error helpers ---

// conn_errorf stores a formatted message in conn.last_error (freeing the
// previous one) and returns it as a Driver_Error. The message is borrowed —
// valid until the next error on this connection, matching how the SQLite
// driver surfaces sqlite3_errmsg.
@(private)
conn_errorf :: proc(conn: ^Pg_Conn, format: string, args: ..any) -> drv.Error {
	if conn != nil {
		if conn.last_error != "" {delete(conn.last_error, conn.allocator)}
		conn.last_error = fmt.aprintf(format, ..args, allocator = conn.allocator)
		return drv.Driver_Error{code = -1, message = conn.last_error}
	}
	return drv.Driver_Error{code = -1, message = "postgres: error"}
}

// --- Connection lifecycle ---

@(private)
pg_open :: proc(
	driver_data: rawptr,
	dsn: string,
	allocator: mem.Allocator,
) -> (
	drv.Conn_Handle,
	drv.Error,
) {
	d, ok, msg := parse_dsn(dsn)
	if !ok {
		return nil, drv.Driver_Error{code = -1, message = msg}
	}
	if requires_tls(d.sslmode) {
		return nil, drv.Driver_Error {
			code = -1,
			message = "postgres: sslmode requires TLS, which is not implemented yet — use sslmode=disable",
		}
	}

	conn := new(Pg_Conn, allocator)
	conn.allocator = allocator
	conn.rbuf = make([dynamic]u8, allocator)
	conn.wbuf = make([dynamic]u8, allocator)

	endpoint := fmt.aprintf("%s:%s", d.host, d.port, allocator = allocator)
	defer delete(endpoint, allocator)

	socket, neterr := net.dial_tcp_from_hostname_and_port_string(endpoint)
	if neterr != nil {
		e := conn_errorf(conn, "postgres: failed to connect to %s: %v", endpoint, neterr)
		return open_fail(conn), e
	}
	conn.socket = socket

	if e := pg_authenticate(conn, d.user, d.dbname, d.password); e != nil {
		net.close(conn.socket)
		return open_fail(conn), e
	}
	return drv.Conn_Handle(conn), nil
}

// open_fail frees the connection's buffers and struct on a failed open. It
// deliberately does NOT free conn.last_error: the returned Driver_Error points
// into it, so it must outlive this call (a small one-time leak on the rare
// connect-failure path).
@(private)
open_fail :: proc(conn: ^Pg_Conn) -> drv.Conn_Handle {
	delete(conn.rbuf)
	delete(conn.wbuf)
	free(conn, conn.allocator)
	return nil
}

@(private)
pg_close_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Pg_Conn)handle
	// Politely tell the server we're going away (best effort).
	clear(&conn.wbuf)
	build_terminate(&conn.wbuf)
	send_all(conn, conn.wbuf[:])
	net.close(conn.socket)

	delete(conn.rbuf)
	delete(conn.wbuf)
	if conn.last_error != "" {delete(conn.last_error, conn.allocator)}
	free(conn, conn.allocator)
	return nil
}

@(private)
pg_ping :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Pg_Conn)handle
	send_simple(conn, "") or_return // empty query → EmptyQueryResponse + ReadyForQuery
	return drain_to_ready(conn)
}

@(private)
pg_reset_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	// Pooled connections are used in autocommit and always drained back to
	// ReadyForQuery, so there is no leftover state to reset.
	return nil
}

// --- exec / query ---

@(private)
send_simple :: proc(conn: ^Pg_Conn, sql: string) -> drv.Error {
	clear(&conn.wbuf)
	build_query(&conn.wbuf, sql)
	return pg_flush(conn)
}

// send_extended issues Parse+Bind(+Describe)+Execute+Sync on the unnamed
// statement/portal for a parameterized query.
@(private)
send_extended :: proc(conn: ^Pg_Conn, sql: string, args: []drv.Value, describe: bool) -> drv.Error {
	clear(&conn.wbuf)
	build_parse(&conn.wbuf, "", sql)
	build_bind(&conn.wbuf, "", "", args)
	if describe {build_describe(&conn.wbuf, 'P', "")}
	build_execute(&conn.wbuf, "", 0)
	build_sync(&conn.wbuf)
	return pg_flush(conn)
}

@(private)
pg_exec :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	res: drv.Result,
	err: drv.Error,
) {
	conn := cast(^Pg_Conn)handle
	if len(args) == 0 {
		send_simple(conn, query_str) or_return
	} else {
		t := translate_placeholders(query_str, conn.allocator)
		defer delete(t, conn.allocator)
		send_extended(conn, t, args, false) or_return
	}
	return exec_drain(conn)
}

@(private)
pg_query :: proc(
	handle: drv.Conn_Handle,
	query_str: string,
	args: []drv.Value,
) -> (
	rows: drv.Rows_Handle,
	err: drv.Error,
) {
	conn := cast(^Pg_Conn)handle
	if len(args) == 0 {
		send_simple(conn, query_str) or_return
	} else {
		t := translate_placeholders(query_str, conn.allocator)
		defer delete(t, conn.allocator)
		send_extended(conn, t, args, true) or_return
	}
	return open_rows(conn)
}

// open_rows reads the result-stream prologue and constructs a streaming Rows.
@(private)
open_rows :: proc(conn: ^Pg_Conn) -> (handle: drv.Rows_Handle, err: drv.Error) {
	cols, done := query_setup(conn) or_return
	rows := new(Pg_Rows, conn.allocator)
	rows.conn = conn
	rows.cols = cols
	rows.done = done
	return drv.Rows_Handle(rows), nil
}

// query_setup reads up to (and including) the RowDescription. If the statement
// returns no rows (e.g. an INSERT issued through query, or an empty query) it
// drains to ReadyForQuery and reports done=true with no columns.
@(private)
query_setup :: proc(conn: ^Pg_Conn) -> (cols: []drv.Column, done: bool, err: drv.Error) {
	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'T': // RowDescription
			return build_columns(conn, payload), false, nil
		case 'C': // CommandComplete with no row description
			drain_to_ready(conn) or_return
			return nil, true, nil
		case 'I': // EmptyQueryResponse
			drain_to_ready(conn) or_return
			return nil, true, nil
		case 'E': // ErrorResponse
			e := parse_error_response(conn, payload)
			drain_to_ready(conn)
			return nil, true, e
		case '1', '2', 'n', 'S', 'N', 't', 'K':
		// ParseComplete / BindComplete / NoData / ParameterStatus /
		// NoticeResponse / ParameterDescription / BackendKeyData — skip
		case 'Z':
			if len(payload) > 0 {conn.tx_status = payload[0]}
			return nil, true, nil
		case:
		// ignore anything unexpected and keep reading
		}
	}
}

// exec_drain consumes a result stream that returns no rows of interest,
// extracting rows_affected from CommandComplete and surfacing any error once
// the stream is drained to ReadyForQuery (so the connection stays reusable).
@(private)
exec_drain :: proc(conn: ^Pg_Conn) -> (res: drv.Result, err: drv.Error) {
	result: drv.Result
	captured: drv.Error
	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'C': // CommandComplete
			result.rows_affected = parse_command_tag(cstr_payload(payload))
		case 'Z': // ReadyForQuery
			if len(payload) > 0 {conn.tx_status = payload[0]}
			if captured != nil {return {}, captured}
			return result, nil
		case 'E': // ErrorResponse
			captured = parse_error_response(conn, payload)
		case:
		// 'D' 'T' '1' '2' 'n' 'S' 'N' 't' 'I' 'K' — ignore, keep draining
		}
	}
}

// drain_to_ready discards messages until ReadyForQuery. Used to leave the
// connection clean after early termination or an error.
@(private)
drain_to_ready :: proc(conn: ^Pg_Conn) -> drv.Error {
	for {
		tag, payload := read_message(conn) or_return
		if tag == 'Z' {
			if len(payload) > 0 {conn.tx_status = payload[0]}
			return nil
		}
	}
}

// --- Rows ---

@(private)
build_columns :: proc(conn: ^Pg_Conn, payload: []byte) -> []drv.Column {
	r := Reader{data = payload}
	n := int(rd_i16(&r))
	if n < 0 {n = 0}
	cols := make([]drv.Column, n, conn.allocator)
	for i in 0 ..< n {
		name := rd_cstr(&r) // borrows rbuf — clone, since rbuf is reused per message
		_ = rd_u32(&r) // table OID
		_ = rd_i16(&r) // column attribute number
		type_oid := rd_u32(&r)
		_ = rd_i16(&r) // type size
		_ = rd_i32(&r) // type modifier
		_ = rd_i16(&r) // format code
		cols[i] = drv.Column {
			name     = strings.clone(name, conn.allocator),
			type_id  = oid_to_typeid(type_oid),
			nullable = true,
		}
	}
	return cols
}

@(private)
pg_rows_columns :: proc(handle: drv.Rows_Handle) -> []drv.Column {
	rows := cast(^Pg_Rows)handle
	return rows.cols
}

@(private)
pg_rows_next :: proc(handle: drv.Rows_Handle, dest: []drv.Value) -> bool {
	rows := cast(^Pg_Rows)handle
	if rows.done {return false}
	for {
		tag, payload, err := read_message(rows.conn)
		if err != nil {
			rows.done = true
			return false
		}
		switch tag {
		case 'D': // DataRow
			decode_data_row(rows, payload, dest)
			return true
		case 'C': // CommandComplete — result finished
			rows.done = true
			drain_to_ready(rows.conn)
			return false
		case 'Z': // ReadyForQuery
			rows.done = true
			if len(payload) > 0 {rows.conn.tx_status = payload[0]}
			return false
		case 'E': // ErrorResponse mid-stream
			parse_error_response(rows.conn, payload)
			rows.done = true
			drain_to_ready(rows.conn)
			return false
		case:
		// 'S' 'N' etc. — skip and keep reading
		}
	}
}

@(private)
decode_data_row :: proc(rows: ^Pg_Rows, payload: []byte, dest: []drv.Value) {
	r := Reader{data = payload}
	ncols := int(rd_i16(&r))
	for i in 0 ..< len(dest) {
		if i >= ncols {
			dest[i] = drv.Null{}
			continue
		}
		length := rd_i32(&r)
		if length < 0 {
			dest[i] = drv.Null{}
		} else {
			raw := rd_bytes(&r, int(length))
			tid := i < len(rows.cols) ? rows.cols[i].type_id : typeid_of(string)
			dest[i] = decode_text_value(tid, raw)
		}
	}
}

@(private)
pg_rows_close :: proc(handle: drv.Rows_Handle) -> drv.Error {
	rows := cast(^Pg_Rows)handle
	if !rows.done {
		drain_to_ready(rows.conn) // consume the rest of the result + ReadyForQuery
	}
	for c in rows.cols {
		delete(c.name, rows.conn.allocator)
	}
	delete(rows.cols, rows.conn.allocator)
	free(rows, rows.conn.allocator)
	return nil
}

// --- Prepared statements ---

@(private)
pg_prepare :: proc(handle: drv.Conn_Handle, query_str: string) -> (drv.Stmt_Handle, drv.Error) {
	conn := cast(^Pg_Conn)handle
	t := translate_placeholders(query_str, conn.allocator)
	defer delete(t, conn.allocator)

	conn.stmt_counter += 1
	name := fmt.aprintf("odin_stmt_%d", conn.stmt_counter, allocator = conn.allocator)

	clear(&conn.wbuf)
	build_parse(&conn.wbuf, name, t)
	build_sync(&conn.wbuf)
	if err := pg_flush(conn); err != nil {
		delete(name, conn.allocator)
		return nil, err
	}
	if err := drain_with_error(conn); err != nil {
		delete(name, conn.allocator)
		return nil, err
	}

	stmt := new(Pg_Stmt, conn.allocator)
	stmt.conn = conn
	stmt.name = name
	return drv.Stmt_Handle(stmt), nil
}

@(private)
pg_stmt_exec :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (res: drv.Result, err: drv.Error) {
	stmt := cast(^Pg_Stmt)handle
	conn := stmt.conn
	clear(&conn.wbuf)
	build_bind(&conn.wbuf, "", stmt.name, args)
	build_execute(&conn.wbuf, "", 0)
	build_sync(&conn.wbuf)
	pg_flush(conn) or_return
	return exec_drain(conn)
}

@(private)
pg_stmt_query :: proc(handle: drv.Stmt_Handle, args: []drv.Value) -> (rows: drv.Rows_Handle, err: drv.Error) {
	stmt := cast(^Pg_Stmt)handle
	conn := stmt.conn
	clear(&conn.wbuf)
	build_bind(&conn.wbuf, "", stmt.name, args)
	build_describe(&conn.wbuf, 'P', "")
	build_execute(&conn.wbuf, "", 0)
	build_sync(&conn.wbuf)
	pg_flush(conn) or_return
	return open_rows(conn)
}

@(private)
pg_stmt_close :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	stmt := cast(^Pg_Stmt)handle
	conn := stmt.conn
	clear(&conn.wbuf)
	build_close(&conn.wbuf, 'S', stmt.name)
	build_sync(&conn.wbuf)
	flush_err := pg_flush(conn)
	if flush_err == nil {drain_to_ready(conn)} // consume CloseComplete + ReadyForQuery
	delete(stmt.name, conn.allocator)
	free(stmt, conn.allocator)
	return flush_err
}

@(private)
pg_stmt_reset :: proc(handle: drv.Stmt_Handle) -> drv.Error {
	// Named prepared statements persist across executions; each Bind opens a
	// fresh unnamed portal that is closed at Sync. Nothing to reset.
	return nil
}

// drain_with_error reads to ReadyForQuery, returning the first ErrorResponse
// (used by prepare, which expects only ParseComplete + ReadyForQuery).
@(private)
drain_with_error :: proc(conn: ^Pg_Conn) -> drv.Error {
	captured: drv.Error
	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'Z':
			if len(payload) > 0 {conn.tx_status = payload[0]}
			return captured
		case 'E':
			captured = parse_error_response(conn, payload)
		case:
		}
	}
}

// --- Transactions ---

@(private)
pg_begin :: proc(handle: drv.Conn_Handle, opts: drv.Tx_Options) -> (tx: drv.Tx_Handle, err: drv.Error) {
	conn := cast(^Pg_Conn)handle
	b: strings.Builder
	strings.builder_init(&b, conn.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "BEGIN")
	switch opts.isolation {
	case .Serializable:
		strings.write_string(&b, " ISOLATION LEVEL SERIALIZABLE")
	case .Repeatable_Read:
		strings.write_string(&b, " ISOLATION LEVEL REPEATABLE READ")
	case .Read_Committed:
		strings.write_string(&b, " ISOLATION LEVEL READ COMMITTED")
	case .Read_Uncommitted:
		strings.write_string(&b, " ISOLATION LEVEL READ UNCOMMITTED")
	case .Default:
	}
	if opts.read_only {strings.write_string(&b, " READ ONLY")}

	send_simple(conn, strings.to_string(b)) or_return
	if _, err := exec_drain(conn); err != nil {
		return nil, err
	}
	return drv.Tx_Handle(conn), nil
}

@(private)
pg_tx_commit :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Pg_Conn)handle
	send_simple(conn, "COMMIT") or_return
	_, err := exec_drain(conn)
	return err
}

@(private)
pg_tx_rollback :: proc(handle: drv.Tx_Handle) -> drv.Error {
	conn := cast(^Pg_Conn)handle
	send_simple(conn, "ROLLBACK") or_return
	_, err := exec_drain(conn)
	return err
}

// --- DSN parsing ---

@(private)
Dsn :: struct {
	host, port, user, password, dbname, sslmode: string,
}

// parse_dsn accepts either a URL (postgres:// / postgresql://) or libpq-style
// "key=value" pairs. Returned strings borrow `dsn`. On an unparseable input it
// returns ok=false with a static message.
@(private)
parse_dsn :: proc(dsn: string) -> (d: Dsn, ok: bool, msg: string) {
	d = Dsn {
		host    = "localhost",
		port    = "5432",
		user    = "postgres",
		sslmode = "prefer",
	}

	s := dsn
	switch {
	case strings.has_prefix(s, "postgres://"), strings.has_prefix(s, "postgresql://"):
		idx := strings.index(s, "://")
		rest := s[idx + 3:]
		if at := strings.index_byte(rest, '@'); at >= 0 {
			ui := rest[:at]
			rest = rest[at + 1:]
			if c := strings.index_byte(ui, ':'); c >= 0 {
				d.user = ui[:c]
				d.password = ui[c + 1:]
			} else if len(ui) > 0 {
				d.user = ui
			}
		}
		if q := strings.index_byte(rest, '?'); q >= 0 {
			apply_pairs(&d, rest[q + 1:], '&')
			rest = rest[:q]
		}
		if sl := strings.index_byte(rest, '/'); sl >= 0 {
			if db := rest[sl + 1:]; db != "" {d.dbname = db}
			rest = rest[:sl]
		}
		if rest != "" {
			if c := strings.last_index_byte(rest, ':'); c >= 0 {
				d.host = rest[:c]
				d.port = rest[c + 1:]
			} else {
				d.host = rest
			}
		}
	case strings.contains(s, "="):
		apply_pairs(&d, s, ' ')
	case s != "":
		d.dbname = s
	}

	if d.dbname == "" {d.dbname = d.user}
	return d, true, ""
}

// apply_pairs splits `s` on `sep` and applies each "key=value" to the Dsn.
@(private)
apply_pairs :: proc(d: ^Dsn, s: string, sep: byte) {
	rest := s
	for len(rest) > 0 {
		// pull the next field
		field: string
		if i := strings.index_byte(rest, sep); i >= 0 {
			field = rest[:i]
			rest = rest[i + 1:]
		} else {
			field = rest
			rest = ""
		}
		if field == "" {continue}
		eq := strings.index_byte(field, '=')
		if eq < 0 {continue}
		set_dsn_kv(d, field[:eq], field[eq + 1:])
	}
}

@(private)
set_dsn_kv :: proc(d: ^Dsn, key, val: string) {
	switch key {
	case "host", "hostaddr":
		d.host = val
	case "port":
		d.port = val
	case "user":
		d.user = val
	case "password":
		d.password = val
	case "dbname", "database":
		d.dbname = val
	case "sslmode":
		d.sslmode = val
	}
}

@(private)
requires_tls :: proc(sslmode: string) -> bool {
	switch sslmode {
	case "require", "verify-ca", "verify-full":
		return true
	}
	return false
}

// --- Small helpers ---

@(private)
cstr_payload :: proc(payload: []byte) -> string {
	if len(payload) > 0 && payload[len(payload) - 1] == 0 {
		return string(payload[:len(payload) - 1])
	}
	return string(payload)
}

// parse_command_tag pulls the trailing integer (rows affected) out of a
// CommandComplete tag like "INSERT 0 1", "UPDATE 3", or "SELECT 5".
@(private)
parse_command_tag :: proc(tag: string) -> i64 {
	sp := strings.last_index_byte(tag, ' ')
	if sp < 0 {return 0}
	v, parsed := strconv.parse_i64(tag[sp + 1:])
	if !parsed {return 0}
	return v
}

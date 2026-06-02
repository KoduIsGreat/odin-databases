package postgres

import "core:net"

import drv "database:sql/driver"

// PostgreSQL frontend/backend protocol v3.0 (the on-the-wire framing).
//
// Every message after the startup phase is: a 1-byte type tag, a big-endian
// Int32 length (counting itself but not the tag), then `length-4` payload
// bytes. The startup/SSL messages omit the type tag. All integers are network
// byte order (big-endian).

PROTOCOL_VERSION :: i32(196608) // 3.0 << 16

// --- Outgoing message framing ---
//
// Messages are built into a reusable byte buffer (conn.wbuf) and flushed with
// pg_flush. Several messages can be appended before one flush (the extended
// query protocol sends Parse+Bind+Describe+Execute+Sync as a batch).

// msg_open writes a message tag (0 = startup, no tag) and a 4-byte length
// placeholder, returning the placeholder offset for msg_close to backpatch.
@(private)
msg_open :: proc(buf: ^[dynamic]u8, tag: u8) -> int {
	if tag != 0 {append(buf, tag)}
	pos := len(buf)
	append(buf, 0, 0, 0, 0)
	return pos
}

// msg_close backpatches the length field (payload + the 4 length bytes).
@(private)
msg_close :: proc(buf: ^[dynamic]u8, pos: int) {
	put_i32_at(buf, pos, i32(len(buf) - pos))
}

@(private)
put_u8 :: proc(buf: ^[dynamic]u8, v: u8) {append(buf, v)}

@(private)
put_i16 :: proc(buf: ^[dynamic]u8, v: i16) {
	u := u16(v)
	append(buf, u8(u >> 8), u8(u))
}

@(private)
put_i32 :: proc(buf: ^[dynamic]u8, v: i32) {
	u := u32(v)
	append(buf, u8(u >> 24), u8(u >> 16), u8(u >> 8), u8(u))
}

@(private)
put_i32_at :: proc(buf: ^[dynamic]u8, pos: int, v: i32) {
	u := u32(v)
	buf[pos] = u8(u >> 24)
	buf[pos + 1] = u8(u >> 16)
	buf[pos + 2] = u8(u >> 8)
	buf[pos + 3] = u8(u)
}

@(private)
put_bytes :: proc(buf: ^[dynamic]u8, s: []byte) {append(buf, ..s)}

@(private)
put_str :: proc(buf: ^[dynamic]u8, s: string) {append(buf, ..transmute([]u8)s)}

// put_cstr writes a NUL-terminated string.
@(private)
put_cstr :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, ..transmute([]u8)s)
	append(buf, 0)
}

// --- Socket I/O ---

@(private)
pg_flush :: proc(conn: ^Pg_Conn) -> drv.Error {
	defer clear(&conn.wbuf)
	return send_all(conn, conn.wbuf[:])
}

@(private)
send_all :: proc(conn: ^Pg_Conn, data: []byte) -> drv.Error {
	off := 0
	for off < len(data) {
		if conn.tls != nil {
			n, ok := tls_write(conn, data[off:])
			if !ok {return conn_errorf(conn, "postgres: TLS write failed%s", tls_error())}
			off += n
		} else {
			n, err := net.send_tcp(conn.socket, data[off:])
			if err != nil {return conn_errorf(conn, "postgres: send failed: %v", err)}
			off += n
		}
	}
	return nil
}

@(private)
recv_exact :: proc(conn: ^Pg_Conn, buf: []byte) -> drv.Error {
	off := 0
	for off < len(buf) {
		if conn.tls != nil {
			n, ok := tls_read(conn, buf[off:])
			if !ok {
				return conn_errorf(conn, "postgres: TLS read failed or connection closed%s", tls_error())
			}
			off += n
		} else {
			n, err := net.recv_tcp(conn.socket, buf[off:])
			if err != nil {return conn_errorf(conn, "postgres: recv failed: %v", err)}
			if n == 0 {return conn_errorf(conn, "postgres: connection closed by server")}
			off += n
		}
	}
	return nil
}

// negotiate_ssl performs the PostgreSQL SSLRequest handshake on the (still
// plaintext) socket: it sends the 8-byte SSLRequest and reads the server's
// single-byte reply. Returns true if the server is willing to do TLS ('S').
@(private)
negotiate_ssl :: proc(conn: ^Pg_Conn) -> (offered: bool, err: drv.Error) {
	clear(&conn.wbuf)
	put_i32(&conn.wbuf, 8) // message length (this field + the magic)
	put_i32(&conn.wbuf, 80877103) // SSLRequest magic (1234 << 16 | 5679)
	if e := send_all(conn, conn.wbuf[:]); e != nil {return false, e}
	clear(&conn.wbuf)

	resp: [1]u8
	if e := recv_exact(conn, resp[:]); e != nil {return false, e}
	return resp[0] == 'S', nil
}

// read_message reads one backend message. The returned payload borrows
// conn.rbuf and is valid only until the next read_message call.
@(private)
read_message :: proc(conn: ^Pg_Conn) -> (tag: u8, payload: []byte, err: drv.Error) {
	hdr: [5]u8
	recv_exact(conn, hdr[:]) or_return
	tag = hdr[0]
	length := int(u32(hdr[1]) << 24 | u32(hdr[2]) << 16 | u32(hdr[3]) << 8 | u32(hdr[4]))
	payload_len := length - 4
	if payload_len < 0 {
		return 0, nil, conn_errorf(conn, "postgres: invalid message length %d", length)
	}
	resize(&conn.rbuf, payload_len)
	if payload_len > 0 {
		recv_exact(conn, conn.rbuf[:payload_len]) or_return
	}
	return tag, conn.rbuf[:payload_len], nil
}

// --- Incoming payload cursor ---

@(private)
Reader :: struct {
	data: []byte,
	pos:  int,
}

@(private)
rd_u8 :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.data) {return 0}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

@(private)
rd_i16 :: proc(r: ^Reader) -> i16 {
	if r.pos + 2 > len(r.data) {r.pos = len(r.data);return 0}
	v := i16(u16(r.data[r.pos]) << 8 | u16(r.data[r.pos + 1]))
	r.pos += 2
	return v
}

@(private)
rd_i32 :: proc(r: ^Reader) -> i32 {
	if r.pos + 4 > len(r.data) {r.pos = len(r.data);return 0}
	v := i32(
		u32(r.data[r.pos]) << 24 |
		u32(r.data[r.pos + 1]) << 16 |
		u32(r.data[r.pos + 2]) << 8 |
		u32(r.data[r.pos + 3]),
	)
	r.pos += 4
	return v
}

@(private)
rd_u32 :: proc(r: ^Reader) -> u32 {return u32(rd_i32(r))}

// rd_cstr returns the next NUL-terminated string (borrowing r.data).
@(private)
rd_cstr :: proc(r: ^Reader) -> string {
	start := r.pos
	for r.pos < len(r.data) && r.data[r.pos] != 0 {r.pos += 1}
	s := string(r.data[start:r.pos])
	if r.pos < len(r.data) {r.pos += 1} // skip NUL
	return s
}

// rd_bytes returns the next n bytes (borrowing r.data).
@(private)
rd_bytes :: proc(r: ^Reader, n: int) -> []byte {
	if n < 0 || r.pos + n > len(r.data) {
		s := r.data[r.pos:]
		r.pos = len(r.data)
		return s
	}
	s := r.data[r.pos:r.pos + n]
	r.pos += n
	return s
}

@(private)
rd_rest :: proc(r: ^Reader) -> []byte {
	s := r.data[r.pos:]
	r.pos = len(r.data)
	return s
}

// --- Message builders ---

// Startup: protocol version, then "key\0value\0" pairs, terminated by a "\0".
@(private)
build_startup :: proc(buf: ^[dynamic]u8, params: [][2]string) {
	pos := msg_open(buf, 0)
	put_i32(buf, PROTOCOL_VERSION)
	for kv in params {
		put_cstr(buf, kv[0])
		put_cstr(buf, kv[1])
	}
	put_u8(buf, 0)
	msg_close(buf, pos)
}

@(private)
build_query :: proc(buf: ^[dynamic]u8, sql: string) {
	pos := msg_open(buf, 'Q')
	put_cstr(buf, sql)
	msg_close(buf, pos)
}

@(private)
build_parse :: proc(buf: ^[dynamic]u8, name, sql: string) {
	pos := msg_open(buf, 'P')
	put_cstr(buf, name)
	put_cstr(buf, sql)
	put_i16(buf, 0) // 0 parameter type OIDs — let the server infer
	msg_close(buf, pos)
}

// build_bind binds `args` to a statement, using TEXT format for both
// parameters and results (one format code applies to all).
@(private)
build_bind :: proc(buf: ^[dynamic]u8, portal, stmt: string, args: []drv.Value) {
	pos := msg_open(buf, 'B')
	put_cstr(buf, portal)
	put_cstr(buf, stmt)
	put_i16(buf, 1) // one param format code...
	put_i16(buf, 0) // ...= TEXT, applies to all params
	put_i16(buf, i16(len(args)))
	for a in args {
		lp := len(buf)
		put_i32(buf, 0) // length placeholder
		start := len(buf)
		if encode_param(buf, a) {
			put_i32_at(buf, lp, i32(len(buf) - start))
		} else {
			put_i32_at(buf, lp, -1) // SQL NULL
		}
	}
	put_i16(buf, 1) // one result format code...
	put_i16(buf, 0) // ...= TEXT, applies to all columns
	msg_close(buf, pos)
}

// build_describe describes a 'S'tatement or 'P'ortal.
@(private)
build_describe :: proc(buf: ^[dynamic]u8, kind: u8, name: string) {
	pos := msg_open(buf, 'D')
	put_u8(buf, kind)
	put_cstr(buf, name)
	msg_close(buf, pos)
}

@(private)
build_execute :: proc(buf: ^[dynamic]u8, portal: string, max_rows: i32) {
	pos := msg_open(buf, 'E')
	put_cstr(buf, portal)
	put_i32(buf, max_rows)
	msg_close(buf, pos)
}

@(private)
build_sync :: proc(buf: ^[dynamic]u8) {
	pos := msg_open(buf, 'S')
	msg_close(buf, pos)
}

// build_close closes a 'S'tatement or 'P'ortal.
@(private)
build_close :: proc(buf: ^[dynamic]u8, kind: u8, name: string) {
	pos := msg_open(buf, 'C')
	put_u8(buf, kind)
	put_cstr(buf, name)
	msg_close(buf, pos)
}

@(private)
build_terminate :: proc(buf: ^[dynamic]u8) {
	pos := msg_open(buf, 'X')
	msg_close(buf, pos)
}

// build_password sends a PasswordMessage ('p'): cleartext or pre-hashed.
@(private)
build_password :: proc(buf: ^[dynamic]u8, password: string) {
	pos := msg_open(buf, 'p')
	put_cstr(buf, password)
	msg_close(buf, pos)
}

// build_sasl_initial sends a SASLInitialResponse ('p').
@(private)
build_sasl_initial :: proc(buf: ^[dynamic]u8, mechanism: string, data: []byte) {
	pos := msg_open(buf, 'p')
	put_cstr(buf, mechanism)
	put_i32(buf, i32(len(data)))
	put_bytes(buf, data)
	msg_close(buf, pos)
}

// build_sasl_response sends a SASLResponse ('p') carrying the client-final
// message (raw SASL bytes, no length prefix).
@(private)
build_sasl_response :: proc(buf: ^[dynamic]u8, data: []byte) {
	pos := msg_open(buf, 'p')
	put_bytes(buf, data)
	msg_close(buf, pos)
}

// --- ErrorResponse / NoticeResponse ---

// parse_error_response reads an ErrorResponse 'E' payload into a Driver_Error,
// stashing a "SEVERITY: message (SQLSTATE XXXXX)" string in conn.last_error.
@(private)
parse_error_response :: proc(conn: ^Pg_Conn, payload: []byte) -> drv.Error {
	r := Reader{data = payload}
	severity, message, code: string
	for {
		field := rd_u8(&r)
		if field == 0 {break}
		val := rd_cstr(&r)
		switch field {
		case 'S', 'V':
			if severity == "" {severity = val}
		case 'M':
			message = val
		case 'C':
			code = val
		}
	}
	return conn_errorf(conn, "%s: %s (SQLSTATE %s)", severity, message, code)
}

// TLS transport for the PostgreSQL driver, gated behind a build flag so the
// default build stays pure-Odin with no C dependency:
//
//   odin build . -define:DATABASE_PG_TLS=true \
//       -extra-linker-flags:-L/opt/homebrew/opt/openssl@3/lib   # macOS homebrew
//
// When DATABASE_PG_TLS is false (the default) this file links no OpenSSL and the
// driver refuses sslmode=require/verify-* with a clear "rebuild with TLS" error.
// When true it links OpenSSL (libssl/libcrypto) and implements `sslmode=require`
// — encrypt the connection without verifying the server certificate. Certificate
// verification (verify-ca / verify-full) and client certs are not done yet.
//
// All wire I/O funnels through send_all/recv_exact (protocol.odin), which pick
// tls_read/tls_write here when conn.tls is non-nil, so the rest of the driver
// (framing, SCRAM auth, codecs) is unchanged by TLS.
package postgres

@(require) import "core:c"
@(require) import "core:fmt"
@(require) import "core:strings"

import drv "database:driver"

DATABASE_PG_TLS :: #config(DATABASE_PG_TLS, false)

// TLS_SUPPORTED reports whether this build can negotiate TLS (i.e. it was built
// with -define:DATABASE_PG_TLS=true). setup_tls consults it before attempting a
// handshake so plaintext-only builds give an actionable error.
TLS_SUPPORTED :: DATABASE_PG_TLS

when DATABASE_PG_TLS {
	foreign import libssl "system:ssl"
	foreign import libcrypto "system:crypto"

	@(private) SSL_METHOD :: struct {}
	@(private) SSL_CTX :: struct {}
	@(private) SSL :: struct {}

	// SSL_set_tlsext_host_name(ssl, name) is a macro over SSL_ctrl.
	@(private) SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
	@(private) TLSEXT_NAMETYPE_host_name :: 0

	@(default_calling_convention = "c")
	foreign libssl {
		TLS_client_method :: proc() -> ^SSL_METHOD ---
		SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
		SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
		SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
		SSL_free :: proc(s: ^SSL) ---
		SSL_set_fd :: proc(s: ^SSL, fd: c.int) -> c.int ---
		SSL_ctrl :: proc(s: ^SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
		SSL_connect :: proc(s: ^SSL) -> c.int ---
		SSL_read :: proc(s: ^SSL, buf: rawptr, num: c.int) -> c.int ---
		SSL_write :: proc(s: ^SSL, buf: rawptr, num: c.int) -> c.int ---
		SSL_shutdown :: proc(s: ^SSL) -> c.int ---
	}

	@(default_calling_convention = "c")
	foreign libcrypto {
		ERR_get_error :: proc() -> c.ulong ---
		ERR_error_string_n :: proc(e: c.ulong, buf: [^]u8, length: c.size_t) ---
	}

	// tls_handshake wraps the connection's already-open socket in a client TLS
	// session and stores it on the connection. `verify` is accepted for the
	// future verify-ca/verify-full modes; this cut implements `require` only
	// (encrypt, no certificate verification).
	@(private)
	tls_handshake :: proc(conn: ^Pg_Conn, server_name: string, verify: bool) -> drv.Error {
		ctx := SSL_CTX_new(TLS_client_method())
		if ctx == nil {
			return conn_errorf(conn, "postgres: SSL_CTX_new failed%s", tls_error())
		}

		s := SSL_new(ctx)
		if s == nil {
			SSL_CTX_free(ctx)
			return conn_errorf(conn, "postgres: SSL_new failed%s", tls_error())
		}
		if SSL_set_fd(s, c.int(i64(conn.socket))) != 1 {
			SSL_free(s)
			SSL_CTX_free(ctx)
			return conn_errorf(conn, "postgres: SSL_set_fd failed%s", tls_error())
		}

		// Server Name Indication — harmless, and required by some servers/proxies.
		if server_name != "" {
			cname := strings.clone_to_cstring(server_name, conn.allocator)
			defer delete(cname, conn.allocator)
			SSL_ctrl(
				s,
				SSL_CTRL_SET_TLSEXT_HOSTNAME,
				c.long(TLSEXT_NAMETYPE_host_name),
				rawptr(cname),
			)
		}

		if SSL_connect(s) != 1 {
			SSL_free(s)
			SSL_CTX_free(ctx)
			return conn_errorf(conn, "postgres: TLS handshake failed%s", tls_error())
		}

		conn.tls = s
		conn.tls_ctx = ctx
		return nil
	}

	@(private)
	tls_write :: proc(conn: ^Pg_Conn, data: []byte) -> (int, bool) {
		if len(data) == 0 {return 0, true}
		ret := SSL_write((^SSL)(conn.tls), rawptr(raw_data(data)), c.int(len(data)))
		return int(ret), ret > 0
	}

	@(private)
	tls_read :: proc(conn: ^Pg_Conn, buf: []byte) -> (int, bool) {
		if len(buf) == 0 {return 0, true}
		ret := SSL_read((^SSL)(conn.tls), rawptr(raw_data(buf)), c.int(len(buf)))
		return int(ret), ret > 0
	}

	@(private)
	tls_close :: proc(conn: ^Pg_Conn) {
		if conn.tls != nil {
			SSL_shutdown((^SSL)(conn.tls))
			SSL_free((^SSL)(conn.tls))
			conn.tls = nil
		}
		if conn.tls_ctx != nil {
			SSL_CTX_free((^SSL_CTX)(conn.tls_ctx))
			conn.tls_ctx = nil
		}
	}

	// tls_error returns the last OpenSSL error formatted as ": <message>", or
	// "" if the error queue is empty.
	@(private)
	tls_error :: proc() -> string {
		e := ERR_get_error()
		if e == 0 {return ""}
		buf: [256]u8
		ERR_error_string_n(e, raw_data(buf[:]), c.size_t(len(buf)))
		n := 0
		for n < len(buf) && buf[n] != 0 {n += 1}
		return fmt.tprintf(": %s", string(buf[:n]))
	}
} else {
	// Plaintext-only build. setup_tls short-circuits before tls_handshake is
	// ever called (TLS_SUPPORTED is false), so these stubs just keep the
	// package compiling; tls_read/tls_write are unreachable because conn.tls
	// stays nil.
	@(private)
	tls_handshake :: proc(conn: ^Pg_Conn, server_name: string, verify: bool) -> drv.Error {
		return drv.Driver_Error{code = -1, message = "postgres: built without TLS support"}
	}
	@(private)
	tls_write :: proc(conn: ^Pg_Conn, data: []byte) -> (int, bool) {return 0, false}
	@(private)
	tls_read :: proc(conn: ^Pg_Conn, buf: []byte) -> (int, bool) {return 0, false}
	@(private)
	tls_close :: proc(conn: ^Pg_Conn) {}
	@(private)
	tls_error :: proc() -> string {return ""}
}

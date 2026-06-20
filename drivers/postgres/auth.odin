package postgres

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:encoding/base64"
import "core:strconv"
import "core:strings"

import drv "database:driver"

// pg_authenticate runs the startup + authentication handshake to the point
// where the server reports ReadyForQuery. Supports AuthenticationOk (trust),
// cleartext password, MD5, and SASL/SCRAM-SHA-256 (the modern default).
@(private)
pg_authenticate :: proc(conn: ^Pg_Conn, user, database, password: string) -> drv.Error {
	params := [][2]string {
		{"user", user},
		{"database", database},
		{"application_name", "odin-databases"},
		{"client_encoding", "UTF8"},
	}
	build_startup(&conn.wbuf, params[:])
	pg_flush(conn) or_return

	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'R':
			r := Reader{data = payload}
			code := rd_i32(&r)
			switch code {
			case 0: // AuthenticationOk
				return finish_startup(conn)
			case 3: // AuthenticationCleartextPassword
				clear(&conn.wbuf)
				build_password(&conn.wbuf, password)
				pg_flush(conn) or_return
			case 5: // AuthenticationMD5Password
				salt := rd_bytes(&r, 4)
				token := md5_token(conn, user, password, salt)
				defer delete(token, conn.allocator)
				clear(&conn.wbuf)
				build_password(&conn.wbuf, token)
				pg_flush(conn) or_return
			case 10: // AuthenticationSASL
				scram_authenticate(conn, &r, password) or_return
			// loop again — the server next sends AuthenticationOk
			case:
				return conn_errorf(
					conn,
					"postgres: unsupported authentication method (%d)",
					code,
				)
			}
		case 'E':
			return parse_error_response(conn, payload)
		case 'N':
		// NoticeResponse during auth — ignore
		case:
			return conn_errorf(
				conn,
				"postgres: unexpected message %q during authentication",
				rune(tag),
			)
		}
	}
}

// finish_startup drains ParameterStatus / BackendKeyData / NoticeResponse
// messages until ReadyForQuery, recording the transaction-status byte.
@(private)
finish_startup :: proc(conn: ^Pg_Conn) -> drv.Error {
	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'Z': // ReadyForQuery
			if len(payload) > 0 {conn.tx_status = payload[0]}
			return nil
		case 'K': // BackendKeyData — pid + secret, kept for interrupt()/CancelRequest
			if len(payload) >= 8 {
				kr := Reader{data = payload}
				conn.backend_pid = rd_i32(&kr)
				conn.backend_secret = rd_i32(&kr)
			}
		case 'S', 'N':
		// ParameterStatus / NoticeResponse — ignore
		case 'E':
			return parse_error_response(conn, payload)
		case:
		// ignore anything else pre-ready
		}
	}
}

// --- SCRAM-SHA-256 (RFC 5802 / RFC 7677) ---

@(private)
scram_authenticate :: proc(conn: ^Pg_Conn, r: ^Reader, password: string) -> drv.Error {
	alloc := conn.allocator

	// The remaining payload lists SASL mechanism names; require SCRAM-SHA-256.
	found := false
	for {
		m := rd_cstr(r)
		if m == "" {break}
		if m == "SCRAM-SHA-256" {found = true}
	}
	if !found {
		return conn_errorf(conn, "postgres: server offered no supported SASL mechanism (need SCRAM-SHA-256)")
	}

	// client-first: gs2-header "n,," + "n=,r=<client-nonce>" (username empty —
	// the server uses the startup `user`). Nonce = base64 of 18 random bytes.
	nonce_raw: [18]u8
	crypto.rand_bytes(nonce_raw[:])
	client_nonce := base64.encode(nonce_raw[:], allocator = alloc)
	defer delete(client_nonce, alloc)
	client_first_bare := strings.concatenate({"n=,r=", client_nonce}, alloc)
	defer delete(client_first_bare, alloc)
	client_first := strings.concatenate({"n,,", client_first_bare}, alloc)
	defer delete(client_first, alloc)

	clear(&conn.wbuf)
	build_sasl_initial(&conn.wbuf, "SCRAM-SHA-256", transmute([]u8)client_first)
	pg_flush(conn) or_return

	// server-first: "r=<combined-nonce>,s=<base64-salt>,i=<iterations>"
	server_first := scram_read_continue(conn, 11) or_return
	combined_nonce, salt_b64, iter_str, parsed := scram_parse_fields(server_first)
	if !parsed {
		return conn_errorf(conn, "postgres: malformed SCRAM server-first message")
	}
	if !strings.has_prefix(combined_nonce, client_nonce) {
		return conn_errorf(conn, "postgres: SCRAM nonce mismatch")
	}
	iterations, iter_ok := strconv.parse_int(iter_str)
	if !iter_ok || iterations <= 0 {
		return conn_errorf(conn, "postgres: bad SCRAM iteration count")
	}
	salt, salt_err := base64.decode(salt_b64, allocator = alloc)
	if salt_err != nil {
		return conn_errorf(conn, "postgres: bad SCRAM salt")
	}
	defer delete(salt, alloc)

	// server_first / combined_nonce borrow the read buffer, which the next
	// read overwrites — copy what the auth message needs.
	server_first_copy := strings.clone(server_first, alloc)
	defer delete(server_first_copy, alloc)
	nonce_copy := strings.clone(combined_nonce, alloc)
	defer delete(nonce_copy, alloc)

	// SaltedPassword = PBKDF2(HMAC-SHA-256, password, salt, i, dkLen=32)
	salted: [32]u8
	pbkdf2.derive(.SHA256, transmute([]u8)password, salt, u32(iterations), salted[:])

	// ClientKey = HMAC(SaltedPassword, "Client Key"); StoredKey = H(ClientKey)
	client_key: [32]u8
	hmac.sum(.SHA256, client_key[:], transmute([]u8)string("Client Key"), salted[:])
	stored_key: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, client_key[:], stored_key[:])

	// AuthMessage = client-first-bare,server-first,client-final-without-proof
	// ("biws" is base64("n,,") — the gs2-header with no channel binding.)
	client_final_bare := strings.concatenate({"c=biws,r=", nonce_copy}, alloc)
	defer delete(client_final_bare, alloc)
	auth_message := strings.concatenate(
		{client_first_bare, ",", server_first_copy, ",", client_final_bare},
		alloc,
	)
	defer delete(auth_message, alloc)

	// ClientSignature = HMAC(StoredKey, AuthMessage); proof = ClientKey XOR sig
	client_sig: [32]u8
	hmac.sum(.SHA256, client_sig[:], transmute([]u8)auth_message, stored_key[:])
	proof: [32]u8
	for i in 0 ..< 32 {proof[i] = client_key[i] ~ client_sig[i]}
	proof_b64 := base64.encode(proof[:], allocator = alloc)
	defer delete(proof_b64, alloc)

	client_final := strings.concatenate({client_final_bare, ",p=", proof_b64}, alloc)
	defer delete(client_final, alloc)

	clear(&conn.wbuf)
	build_sasl_response(&conn.wbuf, transmute([]u8)client_final)
	pg_flush(conn) or_return

	// server-final: "v=<base64(ServerSignature)>" — verify it.
	server_final := scram_read_continue(conn, 12) or_return
	got := server_final
	if strings.has_prefix(got, "v=") {got = got[2:]}

	server_key: [32]u8
	hmac.sum(.SHA256, server_key[:], transmute([]u8)string("Server Key"), salted[:])
	server_sig: [32]u8
	hmac.sum(.SHA256, server_sig[:], transmute([]u8)auth_message, server_key[:])
	expected := base64.encode(server_sig[:], allocator = alloc)
	defer delete(expected, alloc)
	if got != expected {
		return conn_errorf(conn, "postgres: SCRAM server signature verification failed")
	}
	return nil
}

// scram_read_continue reads the next AuthenticationSASL{Continue,Final}
// message and returns its SASL data (borrowing the read buffer).
@(private)
scram_read_continue :: proc(conn: ^Pg_Conn, want_code: i32) -> (data: string, err: drv.Error) {
	for {
		tag, payload := read_message(conn) or_return
		switch tag {
		case 'R':
			r := Reader{data = payload}
			code := rd_i32(&r)
			if code != want_code {
				return "", conn_errorf(
					conn,
					"postgres: expected SASL message %d, got %d",
					want_code,
					code,
				)
			}
			return string(rd_rest(&r)), nil
		case 'E':
			return "", parse_error_response(conn, payload)
		case 'N':
		// notice — ignore
		case:
			return "", conn_errorf(conn, "postgres: unexpected message during SASL exchange")
		}
	}
}

// scram_parse_fields extracts r= / s= / i= from a comma-separated SCRAM
// message (the returned strings borrow `s`).
@(private)
scram_parse_fields :: proc(s: string) -> (nonce, salt, iter: string, ok: bool) {
	rest := s
	for len(rest) > 0 {
		comma := strings.index_byte(rest, ',')
		field := rest if comma < 0 else rest[:comma]
		switch {
		case strings.has_prefix(field, "r="):
			nonce = field[2:]
		case strings.has_prefix(field, "s="):
			salt = field[2:]
		case strings.has_prefix(field, "i="):
			iter = field[2:]
		}
		if comma < 0 {break}
		rest = rest[comma + 1:]
	}
	ok = nonce != "" && salt != "" && iter != ""
	return
}

// md5_token builds the legacy "md5" + hex(md5(hex(md5(password+user)) + salt))
// PasswordMessage payload.
@(private)
md5_token :: proc(conn: ^Pg_Conn, user, password: string, salt: []byte) -> string {
	inner := strings.concatenate({password, user}, conn.allocator)
	defer delete(inner, conn.allocator)
	d1: [16]u8
	hash.hash_bytes_to_buffer(.Insecure_MD5, transmute([]u8)inner, d1[:])
	h1: [32]u8
	to_hex(h1[:], d1[:])

	stage2 := make([]u8, 32 + len(salt), conn.allocator)
	defer delete(stage2, conn.allocator)
	copy(stage2[:32], h1[:])
	copy(stage2[32:], salt)
	d2: [16]u8
	hash.hash_bytes_to_buffer(.Insecure_MD5, stage2, d2[:])
	h2: [32]u8
	to_hex(h2[:], d2[:])

	return strings.concatenate({"md5", string(h2[:])}, conn.allocator)
}

@(private)
to_hex :: proc(dst, src: []byte) {
	for b, i in src {
		dst[i * 2] = hex_digit(b >> 4)
		dst[i * 2 + 1] = hex_digit(b & 0xf)
	}
}

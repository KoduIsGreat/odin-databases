package postgres

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

import drv "database:sql/driver"

// --- PostgreSQL type OIDs ---
//
// The subset we map onto the driver `Value` union. Results are requested in
// TEXT format, so decoding parses these textual representations. Unrecognized
// OIDs fall back to `string` (the raw text), which is always safe.
OID :: enum u32 {
	BOOL        = 16,
	BYTEA       = 17,
	CHAR        = 18,
	NAME        = 19,
	INT8        = 20,
	INT2        = 21,
	INT4        = 23,
	TEXT        = 25,
	OID_T       = 26,
	JSON        = 114,
	FLOAT4      = 700,
	FLOAT8      = 701,
	BPCHAR      = 1042,
	VARCHAR     = 1043,
	DATE        = 1082,
	TIME        = 1083,
	TIMESTAMP   = 1114,
	TIMESTAMPTZ = 1184,
	NUMERIC     = 1700,
	UUID        = 2950,
	JSONB       = 3802,
}

// oid_to_typeid maps a column's PostgreSQL OID to the Odin type the driver
// produces for it at scan time. Mirrors the affinity choices the rest of the
// toolkit makes (int family -> i64, real/numeric -> f64, blob -> []byte,
// date/time family -> time.Time, everything textual -> string).
oid_to_typeid :: proc(oid: u32) -> typeid {
	switch OID(oid) {
	case .BOOL:
		return bool
	case .INT2, .INT4, .INT8, .OID_T:
		return i64
	case .FLOAT4, .FLOAT8, .NUMERIC:
		return f64
	case .BYTEA:
		return []byte
	case .DATE, .TIME, .TIMESTAMP, .TIMESTAMPTZ:
		return time.Time
	case .CHAR, .NAME, .TEXT, .BPCHAR, .VARCHAR, .JSON, .JSONB, .UUID:
		return string
	case:
		return string
	}
}

// --- Result decoding (TEXT format) ---

// decode_text_value turns a column's raw TEXT-format bytes into a driver
// `Value`, guided by the Odin `tid` chosen from the column OID. The returned
// string / []byte borrow `raw` (a slice of the connection's read buffer), so
// they are valid only until the next message is read — the sql layer clones
// on scan. bytea is hex-decoded IN PLACE into `raw`, so it borrows too.
decode_text_value :: proc(tid: typeid, raw: []byte) -> drv.Value {
	switch tid {
	case bool:
		return len(raw) > 0 && (raw[0] == 't' || raw[0] == 'T' || raw[0] == '1')
	case i64:
		v, _ := strconv.parse_i64(string(raw))
		return v
	case f64:
		v, _ := strconv.parse_f64(string(raw))
		return v
	case []byte:
		return decode_bytea(raw)
	case time.Time:
		if t, ok := parse_pg_timestamp(string(raw)); ok {
			return t
		}
		return string(raw)
	case:
		return string(raw)
	}
}

// decode_bytea decodes PostgreSQL's hex bytea text format ("\x68656c6c6f")
// in place into the front of `raw`, returning the decoded prefix. A value
// not in hex format (e.g. the legacy "escape" output) is returned unchanged.
@(private)
decode_bytea :: proc(raw: []byte) -> []byte {
	if len(raw) < 2 || raw[0] != '\\' || (raw[1] != 'x' && raw[1] != 'X') {
		return raw
	}
	hex := raw[2:]
	n := len(hex) / 2
	for i in 0 ..< n {
		hi, hok := hex_nibble(hex[i * 2])
		lo, lok := hex_nibble(hex[i * 2 + 1])
		if !hok || !lok {return raw[:i]}
		raw[i] = hi << 4 | lo
	}
	return raw[:n]
}

@(private)
hex_nibble :: proc(c: byte) -> (byte, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// parse_pg_timestamp parses PostgreSQL's TEXT representations of the date/time
// family into a time.Time (UTC). It accepts:
//   - date:        "2006-01-02"
//   - time:        "15:04:05[.ffffff]"
//   - timestamp:   "2006-01-02 15:04:05[.ffffff]"
//   - timestamptz: "2006-01-02 15:04:05[.ffffff][+-]HH[:MM[:SS]]"
// A trailing timezone offset is folded back to UTC. timestamp/time without an
// offset are treated as UTC (matching the SQLite driver's convention).
@(private)
parse_pg_timestamp :: proc(s: string) -> (out: time.Time, ok: bool) {
	// Time-only ("HH:MM:SS"): no date, ':' in the third character.
	if len(s) >= 8 && s[2] == ':' {
		hour := parse2(s, 0) or_return
		min := parse2(s, 3) or_return
		sec := parse2(s, 6) or_return
		base := time.datetime_to_time(1970, 1, 1, i64(hour), i64(min), i64(sec)) or_return
		frac, _ := parse_fraction(s, 8)
		base._nsec += frac
		return base, true
	}

	if len(s) < 10 {return {}, false}
	if s[4] != '-' || s[7] != '-' {return {}, false}
	year := parse_int_str(s[0:4]) or_return
	month := parse2(s, 5) or_return
	day := parse2(s, 8) or_return

	if len(s) == 10 { 	// date only
		base := time.datetime_to_time(i64(year), i64(month), i64(day), 0, 0, 0) or_return
		return base, true
	}

	if s[10] != ' ' && s[10] != 'T' {return {}, false}
	if len(s) < 19 || s[13] != ':' || s[16] != ':' {return {}, false}
	hour := parse2(s, 11) or_return
	min := parse2(s, 14) or_return
	sec := parse2(s, 17) or_return

	base := time.datetime_to_time(
		i64(year), i64(month), i64(day), i64(hour), i64(min), i64(sec),
	) or_return

	frac, next := parse_fraction(s, 19)
	base._nsec += frac

	// Optional timezone offset "[+-]HH[:MM[:SS]]" — fold back to UTC.
	if next < len(s) && (s[next] == '+' || s[next] == '-') {
		sign: i64 = s[next] == '-' ? -1 : 1
		off := s[next + 1:]
		tz_secs: i64 = 0
		if hh, ok := parse_int_str(off[0:min2(2, len(off))]); ok {
			tz_secs = i64(hh) * 3600
			if len(off) >= 5 && off[2] == ':' {
				if mm, ok2 := parse_int_str(off[3:5]); ok2 {tz_secs += i64(mm) * 60}
				if len(off) >= 8 && off[5] == ':' {
					if ss, ok3 := parse_int_str(off[6:8]); ok3 {tz_secs += i64(ss)}
				}
			}
		}
		base._nsec -= sign * tz_secs * i64(1e9)
	}
	return base, true
}

// parse_fraction reads an optional ".fff..." starting at idx, returning the
// nanosecond value and the index just past the fraction. Up to 9 digits are
// significant; fewer are scaled up, extras ignored.
@(private)
parse_fraction :: proc(s: string, idx: int) -> (nsec: i64, next: int) {
	if idx >= len(s) || s[idx] != '.' {return 0, idx}
	i := idx + 1
	digits := 0
	scale := i64(1e9)
	for i < len(s) && digits < 9 {
		c := s[i]
		if c < '0' || c > '9' {break}
		nsec = nsec * 10 + i64(c - '0')
		scale /= 10
		i += 1
		digits += 1
	}
	// Skip any further digits beyond the 9 we kept.
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {i += 1}
	return nsec * scale, i
}

@(private)
parse2 :: proc(s: string, off: int) -> (int, bool) {
	if off + 2 > len(s) {return 0, false}
	return parse_int_str(s[off:off + 2])
}

@(private)
parse_int_str :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {return 0, false}
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {return 0, false}
		n = n * 10 + int(c - '0')
	}
	return n, true
}

@(private)
min2 :: proc(a, b: int) -> int {return a if a < b else b}

// --- Parameter encoding (TEXT format) ---

// encode_param appends `v`'s TEXT-format representation to `buf`. Returns false
// if the value is SQL NULL (nothing is appended; the caller writes a -1 length).
encode_param :: proc(buf: ^[dynamic]u8, v: drv.Value) -> (ok: bool) {
	#partial switch val in v {
	case drv.Null:
		return false
	case bool:
		append(buf, 't' if val else 'f')
	case i64:
		tmp: [24]u8
		append(buf, ..transmute([]u8)fmt.bprintf(tmp[:], "%d", val))
	case f64:
		tmp: [40]u8
		append(buf, ..strconv.generic_ftoa(tmp[:], val, 'g', -1, 64))
	case string:
		append(buf, ..transmute([]u8)val)
	case []byte:
		append(buf, '\\', 'x')
		for b in val {
			append(buf, hex_digit(b >> 4), hex_digit(b & 0xf))
		}
	case time.Time:
		tmp: [40]u8
		yr, mo, dy := time.date(val)
		hr, mn, sc := time.clock(val)
		ns := time.time_to_unix_nano(val) % i64(1e9)
		if ns < 0 {ns += i64(1e9)}
		s := fmt.bprintf(
			tmp[:],
			"%4d-%02d-%02d %02d:%02d:%02d.%09d",
			yr, int(mo), dy, hr, mn, sc, ns,
		)
		append(buf, ..transmute([]u8)s)
	}
	return true
}

@(private)
hex_digit :: proc(n: byte) -> byte {
	return '0' + n if n < 10 else 'a' + (n - 10)
}

// --- Placeholder translation ---

// translate_placeholders rewrites SQLite-style `?` placeholders into the
// PostgreSQL `$1, $2, ...` form expected by the wire protocol. `?` characters
// inside single-quoted strings, double-quoted identifiers, dollar-quoted
// strings ($$...$$ / $tag$...$tag$), and `--` / `/* */` comments are left
// untouched. Native `$n` placeholders pass through unchanged, so callers may
// write either style.
//
// Caveat: a literal `?` jsonb operator outside of quotes is indistinguishable
// from a placeholder and will be rewritten — use a dollar-quoted string or the
// `jsonb_path_exists`-style functions if you need it.
translate_placeholders :: proc(query: string, allocator := context.allocator) -> string {
	// Fast path: nothing to translate.
	if strings.index_byte(query, '?') < 0 {
		return strings.clone(query, allocator)
	}

	b: strings.Builder
	strings.builder_init(&b, allocator)
	n := 0
	i := 0
	for i < len(query) {
		c := query[i]
		switch c {
		case '\'':
			// Single-quoted string literal; '' is an escaped quote.
			strings.write_byte(&b, c)
			i += 1
			for i < len(query) {
				strings.write_byte(&b, query[i])
				if query[i] == '\'' {
					if i + 1 < len(query) && query[i + 1] == '\'' {
						strings.write_byte(&b, query[i + 1])
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
		case '"':
			// Double-quoted identifier; "" is an escaped quote.
			strings.write_byte(&b, c)
			i += 1
			for i < len(query) {
				strings.write_byte(&b, query[i])
				if query[i] == '"' {
					if i + 1 < len(query) && query[i + 1] == '"' {
						strings.write_byte(&b, query[i + 1])
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
		case '$':
			i = scan_dollar(&b, query, i, &n)
		case '-':
			if i + 1 < len(query) && query[i + 1] == '-' {
				for i < len(query) && query[i] != '\n' {
					strings.write_byte(&b, query[i])
					i += 1
				}
			} else {
				strings.write_byte(&b, c)
				i += 1
			}
		case '/':
			if i + 1 < len(query) && query[i + 1] == '*' {
				strings.write_string(&b, "/*")
				i += 2
				depth := 1
				for i < len(query) && depth > 0 {
					if i + 1 < len(query) && query[i] == '/' && query[i + 1] == '*' {
						strings.write_string(&b, "/*");i += 2;depth += 1
					} else if i + 1 < len(query) && query[i] == '*' && query[i + 1] == '/' {
						strings.write_string(&b, "*/");i += 2;depth -= 1
					} else {
						strings.write_byte(&b, query[i]);i += 1
					}
				}
			} else {
				strings.write_byte(&b, c)
				i += 1
			}
		case '?':
			n += 1
			strings.write_byte(&b, '$')
			strings.write_int(&b, n)
			i += 1
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.to_string(b)
}

// scan_dollar handles a `$` at query[i]. A `$` starting a dollar-quote tag
// ($$ or $tag$) copies the whole quoted region verbatim; a `$` followed by
// digits (a native `$n` placeholder) or anything else is copied as-is.
@(private)
scan_dollar :: proc(b: ^strings.Builder, query: string, i: int, n: ^int) -> int {
	// Find a potential tag: $ [A-Za-z_][A-Za-z0-9_]* $  (tag may be empty).
	j := i + 1
	for j < len(query) {
		c := query[j]
		if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') {
			j += 1
		} else {
			break
		}
	}
	tag_body := query[i + 1:j]
	is_dollar_quote := j < len(query) && query[j] == '$' &&
		(len(tag_body) == 0 || !(tag_body[0] >= '0' && tag_body[0] <= '9'))
	if !is_dollar_quote {
		// Not a dollar-quote (e.g. native `$1`): copy `$` and continue.
		strings.write_byte(b, '$')
		return i + 1
	}

	open := query[i:j + 1] // "$tag$"
	strings.write_string(b, open)
	k := j + 1
	for k < len(query) {
		if k + len(open) <= len(query) && query[k:k + len(open)] == open {
			strings.write_string(b, open)
			return k + len(open)
		}
		strings.write_byte(b, query[k])
		k += 1
	}
	return k
}

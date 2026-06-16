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
//     result; fetch_chunk then walks that buffer, so large result sets are held
//     fully in memory. Blocked on DuckDB's C API: the streaming-result functions
//     (pending_prepared_streaming / stream_fetch_chunk) are deprecated and slated
//     for removal, and the supported pending API still materializes. The reader
//     is already incremental, so a stable streaming path would be a small change.
//   - Composite/exotic types read but cannot be bound as query parameters: pass
//     a string/literal and CAST. (LIST/ARRAY/STRUCT/MAP/UNION scan structurally
//     into []T / [N]T / structs / []struct{key,value}; ENUM/UUID/INTERVAL/BIT/
//     VARINT(BIGNUM)/TIME_NS have native mappings. GEOMETRY/VARIANT read as
//     unsupported cells.)
//   - last_insert_id is always 0 (DuckDB has no rowid/last-insert concept).
//   - Isolation levels are ignored: BEGIN starts DuckDB's snapshot-isolated tx.
//
// Connection model: DuckDB separates the *database* (an engine instance bound
// to a path) from a *connection* (a session on it), and one database can back
// many connections — it handles inter-connection concurrency itself.
//
// A file database may only be opened once per process (a second instance
// collides on DuckDB's file lock), so connections to a file DSN share a single
// reference-counted DuckDB Database, keyed by DSN in a process-global cache and
// closed once its last connection is released. Each pooled connection is its
// own DuckDB Connection on that shared instance, so a file-backed pool runs
// multiple connections concurrently.
//
// In-memory DSNs ("" / ":memory:" / ":memory:<name>") are NOT shared: DuckDB
// makes every in-memory open an independent, isolated database, and the driver
// keeps that semantics so two unrelated `sql.open(":memory:")` calls don't
// collide. The cost is that a `:memory:` pool can't share state across multiple
// connections — pin it with `sql.set_max_open_conns(db, 1)`, or use a file DSN.
package duckdb

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

import ddb "database:bindings/duckdb/duckdb"
import drv "database:sql/driver"

// --- Driver vtable (public) ---

driver := drv.Driver {
	data         = &_cache,
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
	db:         ddb.Database, // file DSN: cache-owned (shared). in-memory: conn-owned.
	con:        ddb.Connection, // owned by this conn
	allocator:  mem.Allocator,
	cache:      ^Duck_Cache, // non-nil only for shared (file) DSNs; nil = conn owns db
	dsn:        string, // owned cache key used to release `db`; set only when cache != nil
	// Holds the most recent error message. DuckDB's error strings live inside
	// the result / prepared statement we destroy right away, so make_error
	// clones the message here (freeing the previous one). Like SQLite's errmsg,
	// a returned Driver_Error.message is borrowed and valid only until the next
	// failing call on this connection (or until the connection is closed).
	last_error: string,
}

// --- Shared-database cache ---
//
// DuckDB allows only one Database instance per file at a time but supports many
// Connections on one Database. Opening a fresh Database per pooled connection
// would self-collide on the file's instance lock, so the cache opens one
// Database per file DSN and hands every connection on that DSN a session on the
// shared instance, closing it when the last connection is released. In-memory
// DSNs bypass the cache entirely (see _is_shared_dsn).

// _is_shared_dsn reports whether a DSN names an on-disk database whose single
// instance must be shared across connections. In-memory DSNs ("" / ":memory:" /
// ":memory:<name>") return false: DuckDB makes each in-memory open an isolated
// database, and the driver preserves that rather than forcing process-wide
// sharing of all `:memory:` handles.
@(private)
_is_shared_dsn :: proc(dsn: string) -> bool {
	return dsn != "" && !strings.has_prefix(dsn, ":memory:")
}

@(private)
Duck_Cache :: struct {
	mu:      sync.Mutex,
	entries: map[string]Duck_Db_Entry, // keyed by DSN
	ready:   bool,
}

// Cache internals (the map and its key strings) live for as long as the cache
// holds entries, which is independent of any single connection's or DB's
// lifetime — so they use the process-global heap allocator rather than a
// caller-provided one, which could be a transient/arena allocator. The map is
// freed once the pool fully drains (see _cache_release).
@(private)
_cache_allocator :: proc() -> mem.Allocator {return runtime.heap_allocator()}

@(private)
Duck_Db_Entry :: struct {
	db:       ddb.Database,
	refcount: int,
	key:      string, // owned clone backing the map key; freed at refcount 0
}

// Process-global cache shared by every DB opened through this driver. Wired into
// `driver.data` so `open` reaches it through the contract; `close_conn` reaches
// it through `Duck_Conn.cache`.
@(private)
_cache: Duck_Cache

// _cache_acquire returns the shared Database for `dsn`, opening it on first use
// and bumping its reference count. The caller must pair every success with
// `_cache_release`.
@(private)
_cache_acquire :: proc(
	cache: ^Duck_Cache,
	dsn: string,
	allocator: mem.Allocator,
) -> (
	ddb.Database,
	drv.Error,
) {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)

	if !cache.ready {
		cache.entries = make(map[string]Duck_Db_Entry, _cache_allocator())
		cache.ready = true
	}

	if entry, found := cache.entries[dsn]; found {
		entry.refcount += 1
		cache.entries[dsn] = entry
		return entry.db, nil
	}

	// Open the Database while holding the lock so two threads can't race to
	// create competing instances of the same DSN.
	cdsn := strings.clone_to_cstring(dsn, allocator)
	defer mem.free(rawptr(cdsn), allocator)

	db: ddb.Database
	if ddb.open(cdsn, &db) != .Success {
		return nil, drv.Driver_Error{code = 1, message = "duckdb: failed to open database"}
	}

	key := strings.clone(dsn, _cache_allocator())
	cache.entries[key] = Duck_Db_Entry {
		db       = db,
		refcount = 1,
		key      = key,
	}
	return db, nil
}

// _cache_release drops one reference to the Database for `dsn`, closing it and
// dropping the cache entry once the count reaches zero.
@(private)
_cache_release :: proc(cache: ^Duck_Cache, dsn: string) {
	sync.mutex_lock(&cache.mu)

	entry, found := cache.entries[dsn]
	if !found {
		sync.mutex_unlock(&cache.mu)
		return
	}

	entry.refcount -= 1
	if entry.refcount > 0 {
		cache.entries[dsn] = entry
		sync.mutex_unlock(&cache.mu)
		return
	}

	// Last reference — remove the entry, then close the Database and free the
	// key outside the lock.
	delete_key(&cache.entries, dsn)
	db := entry.db
	key := entry.key
	// Once the pool fully drains, drop the map too so the cache leaves nothing
	// allocated; the next acquire re-inits it.
	if len(cache.entries) == 0 {
		delete(cache.entries)
		cache.entries = {}
		cache.ready = false
	}
	sync.mutex_unlock(&cache.mu)

	ddb.close(&db)
	delete(key, _cache_allocator())
}

Duck_Stmt :: struct {
	stmt: ddb.Prepared_Statement,
	conn: ^Duck_Conn,
}

// Per-column schema cached once at make_rows so the hot read path performs no
// per-cell metadata lookups.
Col_Meta :: struct {
	type:      ddb.Type, // DuckDB type id
	phys_type: ddb.Type, // physical storage int type for DECIMAL / ENUM
	dec_scale: u8, // DECIMAL scale
	enum_dict: []string, // ENUM labels (owned), nil otherwise
	logical:   ddb.Logical_Type, // kept alive (until close) for composite columns; nil otherwise
}

Duck_Rows :: struct {
	res:        ddb.Result, // owned, materialized result (destroyed on close)
	conn:       ^Duck_Conn,
	cols:       []drv.Column, // allocated; names cloned into the same allocation block
	col_count:  int,
	meta:       []Col_Meta,

	// Current data chunk plus the per-column vector data/validity pointers into
	// it. Read via the modern duckdb_fetch_chunk path — no per-cell value_* calls
	// and no per-cell malloc. Borrowed string/blob cells point directly into
	// `chunk` and stay valid until the next chunk is fetched (i.e. until the
	// rows_next that crosses a chunk boundary), satisfying the driver's
	// borrowed-value contract (valid until the next rows_next / rows_close).
	chunk:      ddb.Data_Chunk,
	chunk_size: u64,
	chunk_row:  u64, // next row index within the current chunk
	vectors:    []ddb.Vector, // per-column vector handle for the current chunk
	vdata:      []rawptr, // vector_get_data per column, for the current chunk
	vvalid:     []^u64, // vector_get_validity per column, for the current chunk

	// Per-row scratch for composite (LIST/STRUCT/MAP/ARRAY) cells: their decoded
	// trees are built here and freed wholesale on the next rows_next / close.
	tree_arena: mem.Dynamic_Arena,
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

// Bind positional args onto a prepared statement (1-based). Validates the
// argument count against the statement's declared parameters first, then binds.
// Returns an Arg_Error for a count/type mismatch, a Driver_Error for a failing
// bind, or nil on success.
@(private)
bind_args :: proc(conn: ^Duck_Conn, stmt: ddb.Prepared_Statement, args: []drv.Value) -> drv.Error {
	if expected := int(ddb.nparams(stmt)); expected != len(args) {
		return drv.Arg_Error{kind = .Wrong_Count, args_expected = expected, args_got = len(args)}
	}
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
			// meaningful query parameter. Surface that rather than silently binding
			// NULL — bind a DECIMAL via a string + CAST instead.
			return drv.Arg_Error {
				kind = .Invalid_Type,
				arg_idx = i,
				value_type = typeid_of(drv.Custom_Value),
			}
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
	case .TIMESTAMP,
	     .TIMESTAMP_S,
	     .TIMESTAMP_MS,
	     .TIMESTAMP_NS,
	     .TIMESTAMP_TZ,
	     .DATE,
	     .TIME,
	     .TIME_NS,
	     .TIME_TZ:
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

// --- UUID (exact, via Custom_Value) ---

// DuckDB stores a UUID as a HUGEINT with the high (sign) bit flipped so values
// sort correctly. We carry that raw i128 in the cell and undo the flip on read.
@(private)
make_uuid_cell :: proc(raw: i128) -> drv.Custom_Value {
	cv: drv.Custom_Value
	(^i128)(&cv.storage)^ = raw
	cv.convert = uuid_convert
	return cv
}

@(private)
uuid_convert :: proc(
	payload: rawptr,
	dest_type: typeid,
	dest: rawptr,
	allocator: mem.Allocator,
) -> bool {
	// Undo DuckDB's sign-bit flip to get the canonical 128-bit value (big-endian).
	u := transmute(u128)((^i128)(payload)^)
	u ~= u128(1) << 127
	bytes: [16]u8
	for i in 0 ..< 16 {
		bytes[i] = u8(u >> uint((15 - i) * 8))
	}
	switch dest_type {
	case [16]u8:
		(^[16]u8)(dest)^ = bytes
	case string:
		(^string)(dest)^ = uuid_to_string(bytes, allocator)
	case:
		return false
	}
	return true
}

@(private)
uuid_to_string :: proc(b: [16]u8, allocator: mem.Allocator) -> string {
	HEX := "0123456789abcdef"
	// 8-4-4-4-12 with dashes = 36 chars.
	out := make([]u8, 36, allocator)
	j := 0
	for i in 0 ..< 16 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-';j += 1
		}
		out[j] = HEX[b[i] >> 4];j += 1
		out[j] = HEX[b[i] & 0xf];j += 1
	}
	return string(out)
}

// --- INTERVAL (exact, via Custom_Value) ---

// Interval is DuckDB's INTERVAL exposed as a scannable Odin type: months and
// days are calendar units kept separate from micros (DuckDB does not normalize
// between them, since months/days have variable length).
Interval :: struct {
	months: i32,
	days:   i32,
	micros: i64,
}
#assert(size_of(Interval) <= size_of(drv.Custom_Value{}.storage))

@(private)
make_interval_cell :: proc(iv: ddb.Interval) -> drv.Custom_Value {
	cv: drv.Custom_Value
	(^Interval)(&cv.storage)^ = Interval {
		months = iv.months,
		days   = iv.days,
		micros = iv.micros,
	}
	cv.convert = interval_convert
	return cv
}

@(private)
interval_convert :: proc(
	payload: rawptr,
	dest_type: typeid,
	dest: rawptr,
	allocator: mem.Allocator,
) -> bool {
	iv := (^Interval)(payload)
	switch dest_type {
	case Interval:
		(^Interval)(dest)^ = iv^
	case string:
		// e.g. "14 months 3 days 01:02:03.5" — months/days only when nonzero.
		secs := iv.micros / 1_000_000
		us := iv.micros % 1_000_000
		hh := secs / 3600
		mm := (secs % 3600) / 60
		ss := secs % 60
		b := strings.builder_make(allocator)
		if iv.months != 0 {fmt.sbprintf(&b, "%d months ", iv.months)}
		if iv.days != 0 {fmt.sbprintf(&b, "%d days ", iv.days)}
		if us != 0 {
			fmt.sbprintf(&b, "%02d:%02d:%02d.%06d", hh, mm, ss, us)
		} else {
			fmt.sbprintf(&b, "%02d:%02d:%02d", hh, mm, ss)
		}
		(^string)(dest)^ = strings.to_string(b)
	case:
		return false
	}
	return true
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
	m := rows.meta[col]
	#partial switch m.type {
	case .LIST, .ARRAY, .STRUCT, .MAP, .UNION:
		dest^ = build_composite_cell(rows, rows.vectors[col], m.logical, row)
		return
	case .BIT:
		dest^ = decode_bit(rows.vdata[col], row, mem.dynamic_arena_allocator(&rows.tree_arena))
		return
	case .BIGNUM:
		dest^ = decode_varint(rows.vdata[col], row, mem.dynamic_arena_allocator(&rows.tree_arena))
		return
	}
	read_vector_cell(rows.vdata[col], m, row, dest)
}

// decode_varint renders DuckDB's arbitrary-precision VARINT (C enum: BIGNUM
// since DuckDB 1.4) as an exact decimal
// string. In-memory it is a 3-byte big-endian header (bit 7 of byte 0 is the
// sign: 1 = positive; the low 23 bits are the magnitude byte count) followed by
// the big-endian magnitude. Negatives store every byte bitwise-complemented (so
// raw byte order matches numeric order), so we undo that first.
@(private)
decode_varint :: proc(data: rawptr, row: u64, a: mem.Allocator) -> drv.Value {
	st := &([^]ddb.String_T)(data)[row]
	n := int(ddb.string_t_length(st^))
	if n < 4 {return "0"}
	src := ([^]u8)(ddb.string_t_data(st))
	negative := (src[0] & 0x80) == 0

	buf := make([]u8, n, context.temp_allocator)
	mask: u8 = 0xff if negative else 0x00
	for i in 0 ..< n {buf[i] = src[i] ~ mask}
	mag := buf[3:] // big-endian magnitude

	digits := bigendian_to_decimal(mag, a)
	if negative && digits != "0" {
		out := make([]u8, len(digits) + 1, a)
		out[0] = '-'
		copy(out[1:], digits)
		delete(digits, a)
		return string(out)
	}
	return digits
}

// bigendian_to_decimal converts a big-endian base-256 magnitude to its decimal
// digits (allocated in `a`) by repeated division by 10.
@(private)
bigendian_to_decimal :: proc(mag: []u8, a: mem.Allocator) -> string {
	work := make([]u8, len(mag), context.temp_allocator)
	copy(work, mag)
	rev := make([dynamic]u8, context.temp_allocator)
	for {
		rem, nonzero := 0, false
		for i in 0 ..< len(work) {
			cur := rem * 256 + int(work[i])
			work[i] = u8(cur / 10)
			rem = cur % 10
			if work[i] != 0 {nonzero = true}
		}
		append(&rev, u8('0' + rem))
		if !nonzero {break}
	}
	out := make([]u8, len(rev), a)
	for i in 0 ..< len(rev) {out[i] = rev[len(rev) - 1 - i]}
	return string(out)
}

// decode_bit renders a BIT value as a '0'/'1' string. In-memory a BIT is a
// string_t whose first byte is the number of unused padding bits in the first
// data byte; the remaining bytes hold the bits MSB-first. The returned string is
// allocated with `a` (the per-row arena for live rows; cloned by scan/detach).
@(private)
decode_bit :: proc(data: rawptr, row: u64, a: mem.Allocator) -> drv.Value {
	st := &([^]ddb.String_T)(data)[row]
	n := int(ddb.string_t_length(st^))
	if n <= 1 {return ""}
	p := ([^]u8)(ddb.string_t_data(st))
	padding := int(p[0])
	nbits := (n - 1) * 8 - padding
	if nbits <= 0 {return ""}
	out := make([]u8, nbits, a)
	for i in 0 ..< nbits {
		bit := padding + i
		out[i] = '0' + ((p[1 + bit / 8] >> uint(7 - bit % 8)) & 1)
	}
	return string(out)
}

// enum_index reads an ENUM's dictionary index from its physical storage int.
@(private)
enum_index :: proc(phys: ddb.Type, data: rawptr, row: u64) -> u64 {
	#partial switch phys {
	case .UTINYINT:
		return u64(([^]u8)(data)[row])
	case .USMALLINT:
		return u64(([^]u16)(data)[row])
	case .UINTEGER:
		return u64(([^]u32)(data)[row])
	case:
		return 0
	}
}

// read_vector_cell decodes one value from a vector's data pointer at `row`,
// given the column's cached metadata. Shared by the top-level reader and (later)
// the composite tree builder. The caller has already handled NULL/validity.
@(private)
read_vector_cell :: proc(data: rawptr, m: Col_Meta, row: u64, dest: ^drv.Value) {
	switch m.type {
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
		dest^ = make_decimal_cell(decimal_raw(m.phys_type, data, row), m.dec_scale)
	case .VARCHAR:
		dest^ = duck_string(&([^]ddb.String_T)(data)[row])
	case .BLOB:
		st := &([^]ddb.String_T)(data)[row]
		n := int(ddb.string_t_length(st^))
		dest^ = (([^]byte)(ddb.string_t_data(st)))[:n]
	case .UUID:
		dest^ = make_uuid_cell(([^]i128)(data)[row])
	case .INTERVAL:
		dest^ = make_interval_cell(([^]ddb.Interval)(data)[row])
	case .ENUM:
		idx := enum_index(m.phys_type, data, row)
		// Labels are owned by the column (cloned at make_rows), so this borrow is
		// valid until close; scan() clones it like any other string.
		dest^ = m.enum_dict[idx] if int(idx) < len(m.enum_dict) else drv.Null{}
	case .TIMESTAMP, .TIMESTAMP_TZ:
		// micros since epoch (TIMESTAMP_TZ stores the UTC instant).
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row] * 1000,
		}
	case .TIMESTAMP_S:
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row] * 1_000_000_000,
		}
	case .TIMESTAMP_MS:
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row] * 1_000_000,
		}
	case .TIMESTAMP_NS:
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row],
		}
	case .DATE:
		dest^ = time.Time {
			_nsec = i64(([^]i32)(data)[row]) * 86_400 * 1_000_000_000,
		}
	case .TIME:
		// micros since midnight.
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row] * 1000,
		}
	case .TIME_NS:
		// nanos since midnight (DuckDB 1.4+).
		dest^ = time.Time {
			_nsec = ([^]i64)(data)[row],
		}
	case .TIME_TZ:
		// Packed 40-bit micros + 24-bit offset; normalize to the UTC instant.
		s := ddb.from_time_tz(([^]ddb.Time_Tz)(data)[row])
		day_us :=
			(i64(s.time.hour) * 3600 + i64(s.time.min) * 60 + i64(s.time.sec)) * 1_000_000 +
			i64(s.time.micros)
		dest^ = time.Time {
			_nsec = (day_us - i64(s.offset) * 1_000_000) * 1000,
		}
	case .INVALID, .LIST, .STRUCT, .MAP, .ARRAY, .UNION, .BIT, .ANY, .BIGNUM, .SQLNULL,
	     .STRING_LITERAL, .INTEGER_LITERAL, .GEOMETRY, .VARIANT:
		dest^ = unsupported_cell(m.type)
	case:
		dest^ = unsupported_cell(m.type)
	}
}

// --- Composite types (LIST / ARRAY / STRUCT / MAP) — structured scan ---
//
// A composite cell is decoded into an owned Node tree, then mapped into the
// caller's Odin destination type at scan time (the destination shape — []T,
// [N]T, a struct, []struct{key,value} — is only known then, via reflection).
//
// The tree is built in the Rows' per-row arena (freed wholesale each rows_next).
// For a live Rows that's enough: scan happens before the next rows_next. For a
// detached Row (query_row), the driver result is freed before scan, so the core
// calls composite_clone to deep-copy the tree into a dedicated owned arena, and
// composite_free to release it. (See drv.Custom_Value's clone/free.)

@(private)
Node_Kind :: enum {
	Scalar,
	List, // LIST / ARRAY (children are elements); MAP (children are key/value structs)
	Struct, // STRUCT (children are field values, named by field_names)
}

@(private)
Node :: struct {
	kind:        Node_Kind,
	scalar:      drv.Value, // when .Scalar
	children:    []Node, // when .List / .Struct
	field_names: []string, // when .Struct
}

@(private)
Composite_Payload :: struct {
	root:  ^Node,
	arena: ^mem.Dynamic_Arena, // non-nil only for a cloned (detached) tree it owns
}
#assert(size_of(Composite_Payload) <= size_of(drv.Custom_Value{}.storage))

// build_node recursively decodes the value at (vector, row) into an owned tree
// using allocator `a`. Scalar leaves borrow VARCHAR/BLOB bytes from the chunk
// (cloned later by scan or composite_clone).
@(private)
build_node :: proc(vec: ddb.Vector, lt: ddb.Logical_Type, row: u64, a: mem.Allocator) -> Node {
	if v := ddb.vector_get_validity(vec);
	   v != nil && !ddb.validity_row_is_valid(v, ddb.Idx_T(row)) {
		return Node{kind = .Scalar, scalar = drv.Null{}}
	}
	t := ddb.get_type_id(lt)
	#partial switch t {
	case .LIST, .MAP:
		// MAP is physically LIST<STRUCT(key, value)>; list_type_child_type accepts both.
		child_vec := ddb.list_vector_get_child(vec)
		child_lt := ddb.list_type_child_type(lt)
		defer ddb.destroy_logical_type(&child_lt)
		e := ([^]ddb.List_Entry)(ddb.vector_get_data(vec))[row]
		kids := make([]Node, int(e.length), a)
		for k in 0 ..< e.length {
			kids[k] = build_node(child_vec, child_lt, e.offset + k, a)
		}
		return Node{kind = .List, children = kids}
	case .ARRAY:
		size := u64(ddb.array_type_array_size(lt))
		child_vec := ddb.array_vector_get_child(vec)
		child_lt := ddb.array_type_child_type(lt)
		defer ddb.destroy_logical_type(&child_lt)
		base := row * size
		kids := make([]Node, int(size), a)
		for k in 0 ..< size {
			kids[k] = build_node(child_vec, child_lt, base + k, a)
		}
		return Node{kind = .List, children = kids}
	case .STRUCT:
		n := int(ddb.struct_type_child_count(lt))
		kids := make([]Node, n, a)
		names := make([]string, n, a)
		for c in 0 ..< n {
			ci := ddb.Idx_T(c)
			cname := ddb.struct_type_child_name(lt, ci)
			names[c] = strings.clone(string(cname), a)
			ddb.free(rawptr(cname)) // struct_type_child_name must be duckdb_free'd
			clt := ddb.struct_type_child_type(lt, ci)
			kids[c] = build_node(ddb.struct_vector_get_child(vec, ci), clt, row, a)
			ddb.destroy_logical_type(&clt)
		}
		return Node{kind = .Struct, children = kids, field_names = names}
	case .UNION:
		// A UNION is physically a STRUCT: child 0 is the tag, children 1..N are the
		// members. Expose it as a struct of members (the inactive ones are NULL),
		// so it scans into a struct with Maybe(T) member fields.
		n := int(ddb.union_type_member_count(lt))
		kids := make([]Node, n, a)
		names := make([]string, n, a)
		for i in 0 ..< n {
			mi := ddb.Idx_T(i)
			mname := ddb.union_type_member_name(lt, mi)
			names[i] = strings.clone(string(mname), a)
			ddb.free(rawptr(mname))
			mlt := ddb.union_type_member_type(lt, mi)
			kids[i] = build_node(ddb.struct_vector_get_child(vec, mi + 1), mlt, row, a)
			ddb.destroy_logical_type(&mlt)
		}
		return Node{kind = .Struct, children = kids, field_names = names}
	case .ENUM:
		idx := enum_index(ddb.enum_internal_type(lt), ddb.vector_get_data(vec), row)
		lbl := ddb.enum_dictionary_value(lt, ddb.Idx_T(idx))
		s := strings.clone(string(lbl), a)
		ddb.free(rawptr(lbl)) // enum_dictionary_value must be duckdb_free'd
		return Node{kind = .Scalar, scalar = s}
	case .BIT:
		return Node{kind = .Scalar, scalar = decode_bit(ddb.vector_get_data(vec), row, a)}
	case .BIGNUM:
		return Node{kind = .Scalar, scalar = decode_varint(ddb.vector_get_data(vec), row, a)}
	case:
		m := Col_Meta {
			type = t,
		}
		if t == .DECIMAL {
			m.dec_scale = ddb.decimal_scale(lt)
			m.phys_type = ddb.decimal_internal_type(lt)
		}
		val: drv.Value
		read_vector_cell(ddb.vector_get_data(vec), m, row, &val)
		return Node{kind = .Scalar, scalar = val}
	}
}

@(private)
build_composite_cell :: proc(
	rows: ^Duck_Rows,
	vec: ddb.Vector,
	lt: ddb.Logical_Type,
	row: u64,
) -> drv.Custom_Value {
	a := mem.dynamic_arena_allocator(&rows.tree_arena)
	root := new(Node, a)
	root^ = build_node(vec, lt, row, a)
	cv: drv.Custom_Value
	p := (^Composite_Payload)(&cv.storage)
	p.root = root
	cv.convert = composite_convert
	cv.clone = composite_clone
	cv.free = composite_free
	return cv
}

@(private)
composite_convert :: proc(
	payload: rawptr,
	dest_type: typeid,
	dest: rawptr,
	allocator: mem.Allocator,
) -> bool {
	return map_node((^Composite_Payload)(payload).root^, dest_type, dest, allocator)
}

@(private)
composite_clone :: proc(storage: ^[2]i128, allocator: mem.Allocator) {
	p := (^Composite_Payload)(storage)
	arena := new(mem.Dynamic_Arena, allocator)
	mem.dynamic_arena_init(arena, block_allocator = allocator, array_allocator = allocator)
	a := mem.dynamic_arena_allocator(arena)
	root := new(Node, a)
	root^ = clone_node(p.root^, a)
	p.root = root
	p.arena = arena
}

@(private)
composite_free :: proc(storage: ^[2]i128, allocator: mem.Allocator) {
	p := (^Composite_Payload)(storage)
	if p.arena != nil {
		owner := p.arena.block_allocator
		mem.dynamic_arena_destroy(p.arena)
		free(p.arena, owner)
		p.arena = nil
	}
}

// clone_node deep-copies a Node tree into allocator `a`, including borrowed
// string/[]byte scalar leaves, so the copy outlives the driver result.
@(private)
clone_node :: proc(n: Node, a: mem.Allocator) -> Node {
	out := n
	if n.kind == .Scalar {
		#partial switch v in n.scalar {
		case string:
			out.scalar = strings.clone(v, a)
		case []byte:
			b := make([]byte, len(v), a)
			copy(b, v)
			out.scalar = b
		}
		return out
	}
	if n.children != nil {
		out.children = make([]Node, len(n.children), a)
		for i in 0 ..< len(n.children) {
			out.children[i] = clone_node(n.children[i], a)
		}
	}
	if n.field_names != nil {
		out.field_names = make([]string, len(n.field_names), a)
		for i in 0 ..< len(n.field_names) {
			out.field_names[i] = strings.clone(n.field_names[i], a)
		}
	}
	return out
}

// map_node materializes a Node tree into the destination of type `tid`:
//   LIST   -> []T or [N]T   STRUCT -> a struct matched by field name
//   MAP    -> []struct{key, value}   scalar -> the scalar coercions of set_scalar
// A NULL (a null value, list element, or struct field) leaves the destination at
// its zero value — or None when the destination is a Maybe(T). Returns false on
// a shape/type mismatch.
@(private)
map_node :: proc(node: Node, tid: typeid, dest: rawptr, a: mem.Allocator) -> bool {
	// A NULL maps to the zero value of any destination (and to None for a Maybe).
	if node.kind == .Scalar {
		if _, is_null := node.scalar.(drv.Null); is_null {
			return true
		}
	}
	// Maybe(T): scan the inner T, then mark the union non-nil. (A NULL was already
	// handled above, leaving the union at its zero value, i.e. None.)
	if inner, tag_off, tag_sz, is_maybe := maybe_union(tid); is_maybe {
		if !map_node(node, inner, dest, a) {return false}
		write_union_tag(dest, tag_off, tag_sz, 1)
		return true
	}
	// Scalars (including []byte BLOB, time.Time, the typed exotics) go straight to
	// the scalar coercions, even when their Odin type is a slice/array/struct.
	if node.kind == .Scalar {
		return set_scalar(node.scalar, tid, dest, a)
	}
	ti := runtime.type_info_base(type_info_of(tid))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Slice:
		if node.kind != .List {return false}
		count := len(node.children)
		if count == 0 {
			(^runtime.Raw_Slice)(dest)^ = runtime.Raw_Slice{nil, 0}
			return true
		}
		data, err := mem.alloc(count * info.elem_size, info.elem.align, a)
		if err != nil {return false}
		for i in 0 ..< count {
			ep := rawptr(uintptr(data) + uintptr(i * info.elem_size))
			if !map_node(node.children[i], info.elem.id, ep, a) {return false}
		}
		(^runtime.Raw_Slice)(dest)^ = runtime.Raw_Slice{data, count}
		return true
	case runtime.Type_Info_Array:
		if node.kind != .List {return false}
		n := min(info.count, len(node.children))
		for i in 0 ..< n {
			ep := rawptr(uintptr(dest) + uintptr(i * info.elem_size))
			if !map_node(node.children[i], info.elem.id, ep, a) {return false}
		}
		return true
	case runtime.Type_Info_Struct:
		if node.kind != .Struct {return false}
		for fi in 0 ..< int(info.field_count) {
			for ci in 0 ..< len(node.field_names) {
				if node.field_names[ci] == info.names[fi] {
					fptr := rawptr(uintptr(dest) + info.offsets[fi])
					if !map_node(node.children[ci], info.types[fi].id, fptr, a) {return false}
					break
				}
			}
		}
		return true
	case runtime.Type_Info_Map:
		// A MAP arrives as a List of STRUCT(key, value) nodes (its physical form).
		if node.kind != .List {return false}
		rm := (^runtime.Raw_Map)(dest)
		if rm.allocator.procedure == nil {rm.allocator = a}
		kbuf, kerr := mem.alloc(info.key.size, info.key.align, context.temp_allocator)
		vbuf, verr := mem.alloc(info.value.size, info.value.align, context.temp_allocator)
		if kerr != nil || verr != nil {return false}
		for child in node.children {
			kn, vn := composite_field(child, "key"), composite_field(child, "value")
			if kn == nil || vn == nil {return false}
			mem.zero(kbuf, info.key.size)
			mem.zero(vbuf, info.value.size)
			if !map_node(kn^, info.key.id, kbuf, a) {return false}
			if !map_node(vn^, info.value.id, vbuf, a) {return false}
			runtime.__dynamic_map_set_without_hash(rm, info.map_info, kbuf, vbuf)
		}
		return true
	case:
		return false
	}
}

// composite_field returns the named child of a Struct node, or nil.
@(private)
composite_field :: proc(node: Node, name: string) -> ^Node {
	for i in 0 ..< len(node.field_names) {
		if node.field_names[i] == name {return &node.children[i]}
	}
	return nil
}

// set_scalar writes a scalar drv.Value into a destination of type `tid`,
// mirroring the core scan layer's coercions (it runs inside the driver because
// the core only sees the top-level composite cell). Strings/blobs are cloned
// into `a`; a nested Custom_Value (e.g. DECIMAL in a list) delegates to its
// convert.
@(private)
set_scalar :: proc(val: drv.Value, tid: typeid, dest: rawptr, a: mem.Allocator) -> bool {
	switch v in val {
	case bool:
		if tid != bool {return false}
		(^bool)(dest)^ = v
	case i64:
		switch tid {
		case i64:
			(^i64)(dest)^ = v
		case int:
			(^int)(dest)^ = int(v)
		case i32:
			(^i32)(dest)^ = i32(v)
		case i16:
			(^i16)(dest)^ = i16(v)
		case i8:
			(^i8)(dest)^ = i8(v)
		case u64:
			(^u64)(dest)^ = u64(v)
		case u32:
			(^u32)(dest)^ = u32(v)
		case u16:
			(^u16)(dest)^ = u16(v)
		case u8:
			(^u8)(dest)^ = u8(v)
		case f64:
			(^f64)(dest)^ = f64(v)
		case f32:
			(^f32)(dest)^ = f32(v)
		case bool:
			(^bool)(dest)^ = v != 0
		case:
			return false
		}
	case i128:
		switch tid {
		case i128:
			(^i128)(dest)^ = v
		case u128:
			(^u128)(dest)^ = u128(v)
		case i64:
			(^i64)(dest)^ = i64(v)
		case u64:
			(^u64)(dest)^ = u64(v)
		case f64:
			(^f64)(dest)^ = f64(v)
		case:
			return false
		}
	case u128:
		switch tid {
		case u128:
			(^u128)(dest)^ = v
		case i128:
			(^i128)(dest)^ = i128(v)
		case u64:
			(^u64)(dest)^ = u64(v)
		case f64:
			(^f64)(dest)^ = f64(v)
		case:
			return false
		}
	case f64:
		switch tid {
		case f64:
			(^f64)(dest)^ = v
		case f32:
			(^f32)(dest)^ = f32(v)
		case:
			return false
		}
	case string:
		if tid != string {return false}
		(^string)(dest)^ = strings.clone(v, a)
	case []byte:
		if tid != []byte {return false}
		b := make([]byte, len(v), a)
		copy(b, v)
		(^[]byte)(dest)^ = b
	case time.Time:
		if tid != time.Time {return false}
		(^time.Time)(dest)^ = v
	case drv.Custom_Value:
		if v.convert == nil {return false}
		cv := v
		return v.convert(&cv.storage, tid, dest, a)
	case drv.Null:
	// Leave the destination at its zero value.
	}
	return true
}

// maybe_union reports whether tid is a nil-able single-variant union (Maybe(T)),
// returning the inner variant's typeid and the union's tag layout. Mirrors the
// core scan layer's helper of the same name (the core's is private).
@(private)
maybe_union :: proc(tid: typeid) -> (inner: typeid, tag_offset: uintptr, tag_size: int, ok: bool) {
	ti := runtime.type_info_base(type_info_of(tid))
	u, is_union := ti.variant.(runtime.Type_Info_Union)
	if !is_union {return}
	if len(u.variants) != 1 || u.no_nil {return}
	return u.variants[0].id, u.tag_offset, u.tag_type.size, true
}

@(private)
write_union_tag :: proc(ptr: rawptr, tag_offset: uintptr, tag_size: int, tag: u64) {
	tagptr := rawptr(uintptr(ptr) + tag_offset)
	switch tag_size {
	case 1:
		(^u8)(tagptr)^ = u8(tag)
	case 2:
		(^u16)(tagptr)^ = u16(tag)
	case 4:
		(^u32)(tagptr)^ = u32(tag)
	case 8:
		(^u64)(tagptr)^ = u64(tag)
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
	rows.meta = make([]Col_Meta, rows.col_count, a)
	rows.vectors = make([]ddb.Vector, rows.col_count, a)
	rows.vdata = make([]rawptr, rows.col_count, a)
	rows.vvalid = make([]^u64, rows.col_count, a)
	mem.dynamic_arena_init(&rows.tree_arena, block_allocator = a, array_allocator = a)

	for i in 0 ..< rows.col_count {
		ci := ddb.Idx_T(i)
		t := ddb.column_type(&rows.res, ci)
		rows.meta[i] = make_col_meta(ddb.column_logical_type(&rows.res, ci), t, a)
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

// make_col_meta extracts the read-time metadata for one column from its logical
// type, taking ownership of `lt` (it is destroyed here unless retained for a
// composite column, which keeps it alive until rows_close).
@(private)
make_col_meta :: proc(lt: ddb.Logical_Type, t: ddb.Type, a: mem.Allocator) -> (m: Col_Meta) {
	lt := lt
	m.type = t
	switch t {
	case .DECIMAL:
		m.dec_scale = ddb.decimal_scale(lt)
		m.phys_type = ddb.decimal_internal_type(lt)
	case .ENUM:
		m.phys_type = ddb.enum_internal_type(lt)
		n := int(ddb.enum_dictionary_size(lt))
		m.enum_dict = make([]string, n, a)
		for j in 0 ..< n {
			m.enum_dict[j] = strings.clone(string(ddb.enum_dictionary_value(lt, ddb.Idx_T(j))), a)
		}
	case .INVALID,
	     .BOOLEAN,
	     .TINYINT,
	     .SMALLINT,
	     .INTEGER,
	     .BIGINT,
	     .UTINYINT,
	     .USMALLINT,
	     .UINTEGER,
	     .UBIGINT,
	     .FLOAT,
	     .DOUBLE,
	     .TIMESTAMP,
	     .DATE,
	     .TIME,
	     .INTERVAL,
	     .HUGEINT,
	     .UHUGEINT,
	     .VARCHAR,
	     .BLOB,
	     .TIMESTAMP_S,
	     .TIMESTAMP_MS,
	     .TIMESTAMP_NS,
	     .UUID,
	     .BIT,
	     .TIME_TZ,
	     .TIMESTAMP_TZ,
	     .ANY,
	     .BIGNUM,
	     .SQLNULL,
	     .STRING_LITERAL,
	     .INTEGER_LITERAL,
	     .TIME_NS,
	     .GEOMETRY,
	     .VARIANT:
	// Scalar / self-describing: nothing extra to cache.
	case .LIST, .STRUCT, .MAP, .ARRAY, .UNION:
		// Composite: retain the logical type so the reader can walk child types.
		m.logical = lt
		return
	}
	ddb.destroy_logical_type(&lt)
	return
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
		rows.vectors[i] = v
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
	db: ddb.Database
	cache: ^Duck_Cache // non-nil iff this DSN's Database is cache-owned

	if _is_shared_dsn(dsn) {
		cache = cast(^Duck_Cache)driver_data
		if cache == nil {cache = &_cache}
		derr: drv.Error
		db, derr = _cache_acquire(cache, dsn, allocator)
		if derr != nil {
			return nil, derr
		}
	} else {
		// In-memory: each connection owns its own isolated DuckDB database.
		cdsn := strings.clone_to_cstring(dsn, allocator)
		defer mem.free(rawptr(cdsn), allocator)
		if ddb.open(cdsn, &db) != .Success {
			return nil, drv.Driver_Error{code = 1, message = "duckdb: failed to open database"}
		}
	}

	con: ddb.Connection
	if ddb.connect(db, &con) != .Success {
		if cache != nil {
			_cache_release(cache, dsn) // drop the ref we just took
		} else {
			ddb.close(&db)
		}
		return nil, drv.Driver_Error{code = 1, message = "duckdb: failed to connect"}
	}

	conn := new(Duck_Conn, allocator)
	conn.db = db
	conn.con = con
	conn.allocator = allocator
	conn.cache = cache
	if cache != nil {conn.dsn = strings.clone(dsn, allocator)}
	return drv.Conn_Handle(conn), nil
}

@(private)
duckdb_close_conn :: proc(handle: drv.Conn_Handle) -> drv.Error {
	conn := cast(^Duck_Conn)handle
	// Disconnect this session first, then release the Database. For a shared
	// (file) DSN that drops our cache reference (closing it iff we were the last
	// connection); for an in-memory DSN this connection owns the Database.
	ddb.disconnect(&conn.con)
	if conn.cache != nil {
		_cache_release(conn.cache, conn.dsn)
		delete(conn.dsn, conn.allocator)
	} else {
		ddb.close(&conn.db)
	}
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
prepare_stmt :: proc(conn: ^Duck_Conn, query_str: string) -> (ddb.Prepared_Statement, drv.Error) {
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
	// Release the previous row's composite trees (borrowed values are only valid
	// until this call). Borrowed string/blob cells live in the chunk and are
	// released when a chunk boundary is crossed below.
	mem.dynamic_arena_free_all(&rows.tree_arena)
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
	mem.dynamic_arena_destroy(&rows.tree_arena)
	for c in rows.cols {
		delete(c.name, a)
	}
	for &m in rows.meta {
		for s in m.enum_dict {delete(s, a)}
		delete(m.enum_dict, a)
		if m.logical != nil {ddb.destroy_logical_type(&m.logical)}
	}
	delete(rows.cols, a)
	delete(rows.meta, a)
	delete(rows.vectors, a)
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

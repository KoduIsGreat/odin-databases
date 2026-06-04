// Package duckdb provides a minimal, hand-written Odin binding to the stable
// DuckDB C API (duckdb.h). It exposes only the surface the `database:drivers/duckdb`
// driver needs: connection lifecycle, eager queries, prepared statements, and
// per-cell value access. It is intentionally NOT a complete binding — the data
// chunk / vector streaming API, appenders, extraction, and the type-system
// helpers are omitted. Add to it as the driver grows.
//
// The DuckDB C API is documented at https://duckdb.org/docs/api/c/overview.
//
// The package is named `duckdb_c` (not `duckdb`) so it can be imported
// alongside the `database:drivers/duckdb` driver package without a name clash.
package duckdb_c

import "core:c"

// Prebuilt DuckDB libraries live under ../lib/<os>_<arch>/. They are NOT
// checked in (each is ~50MB); fetch one for your host with ../fetch_libs.sh
// (or `just duckdb-lib`). We link the shared library, so the loader must be
// able to find it at runtime — the `just` recipes set LD_LIBRARY_PATH /
// DYLD_LIBRARY_PATH to the lib dir for you.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/linux_amd64/libduckdb.so", "system:c"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/linux_arm64/libduckdb.so", "system:c"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/darwin_arm64/libduckdb.dylib", "system:c"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/darwin_amd64/libduckdb.dylib", "system:c"}
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib "../lib/windows_amd64/duckdb.lib"
} else {
	#panic(
		"odin-databases/duckdb: no prebuilt DuckDB library configured for this OS/ARCH. " +
		"Fetch one into bindings/duckdb/lib/<os>_<arch>/ and add a matching branch here.",
	)
}

// --- Scalar typedefs ---------------------------------------------------------

idx_t :: u64

// State is the duckdb_state success/error enum returned by most calls.
State :: enum c.int {
	Success = 0,
	Error   = 1,
}

// Type mirrors the DUCKDB_TYPE enum (the logical type id of a column).
Type :: enum c.int {
	INVALID      = 0,
	BOOLEAN      = 1,
	TINYINT      = 2,
	SMALLINT     = 3,
	INTEGER      = 4,
	BIGINT       = 5,
	UTINYINT     = 6,
	USMALLINT    = 7,
	UINTEGER     = 8,
	UBIGINT      = 9,
	FLOAT        = 10,
	DOUBLE       = 11,
	TIMESTAMP    = 12,
	DATE         = 13,
	TIME         = 14,
	INTERVAL     = 15,
	HUGEINT      = 16,
	VARCHAR      = 17,
	BLOB         = 18,
	DECIMAL      = 19,
	TIMESTAMP_S  = 20,
	TIMESTAMP_MS = 21,
	TIMESTAMP_NS = 22,
	ENUM         = 23,
	LIST         = 24,
	STRUCT       = 25,
	MAP          = 26,
	UUID         = 27,
	UNION        = 28,
	BIT          = 29,
	TIME_TZ      = 30,
	TIMESTAMP_TZ = 31,
	UHUGEINT     = 32,
	ARRAY        = 33,
	ANY          = 34,
	VARINT       = 35,
	SQLNULL      = 36,
}

// --- Opaque handles ----------------------------------------------------------
//
// In the C API these are `typedef struct { void *internal_ptr; } *duckdb_x`,
// i.e. each is already a pointer. We model them as opaque pointers; out-params
// (`duckdb_x *`) become `^Handle` in Odin.

Database           :: distinct rawptr
Connection         :: distinct rawptr
Prepared_Statement :: distinct rawptr

// --- Value structs (passed/returned by value) --------------------------------

// Date is days since 1970-01-01.
Date :: struct {
	days: i32,
}

// Time is microseconds since 00:00:00.
Time :: struct {
	micros: i64,
}

// Timestamp is microseconds since 1970-01-01 00:00:00.
Timestamp :: struct {
	micros: i64,
}

// Blob is a byte pointer + size. For values read out of a result, the data
// pointer is owned by DuckDB and must be released with `free`.
Blob :: struct {
	data: rawptr,
	size: idx_t,
}

// Result is duckdb_result. The `deprecated_*` fields are part of the ABI and
// must stay in this layout, but should be read through the accessor procs
// (column_count, etc). Free with `destroy_result`.
Result :: struct {
	deprecated_column_count:  idx_t,
	deprecated_row_count:     idx_t,
	deprecated_rows_changed:  idx_t,
	deprecated_columns:       rawptr,
	deprecated_error_message: cstring,
	internal_data:            rawptr,
}

// --- Foreign procedures ------------------------------------------------------

@(default_calling_convention = "c", link_prefix = "duckdb_")
foreign lib {
	// Connection lifecycle.
	open       :: proc(path: cstring, out_database: ^Database) -> State ---
	close      :: proc(database: ^Database) ---
	connect    :: proc(database: Database, out_connection: ^Connection) -> State ---
	disconnect :: proc(connection: ^Connection) ---
	interrupt  :: proc(connection: Connection) ---

	// Eager query execution (materializes the full result).
	query          :: proc(connection: Connection, q: cstring, out_result: ^Result) -> State ---
	destroy_result :: proc(result: ^Result) ---

	// Result metadata.
	column_name  :: proc(result: ^Result, col: idx_t) -> cstring ---
	column_type  :: proc(result: ^Result, col: idx_t) -> Type ---
	column_count :: proc(result: ^Result) -> idx_t ---
	row_count    :: proc(result: ^Result) -> idx_t ---
	rows_changed :: proc(result: ^Result) -> idx_t ---
	result_error :: proc(result: ^Result) -> cstring ---

	// Per-cell value access (the deprecated-but-stable convenience API).
	// value_varchar returns a malloc'd copy the caller must `free`.
	value_is_null   :: proc(result: ^Result, col, row: idx_t) -> bool ---
	value_boolean   :: proc(result: ^Result, col, row: idx_t) -> bool ---
	value_int64     :: proc(result: ^Result, col, row: idx_t) -> i64 ---
	value_double    :: proc(result: ^Result, col, row: idx_t) -> f64 ---
	value_varchar   :: proc(result: ^Result, col, row: idx_t) -> cstring ---
	value_blob      :: proc(result: ^Result, col, row: idx_t) -> Blob ---
	value_timestamp :: proc(result: ^Result, col, row: idx_t) -> Timestamp ---
	value_date      :: proc(result: ^Result, col, row: idx_t) -> Date ---
	value_time      :: proc(result: ^Result, col, row: idx_t) -> Time ---

	// Frees memory handed back by the C API (varchar/blob copies).
	free :: proc(ptr: rawptr) ---

	// Prepared statements.
	prepare          :: proc(connection: Connection, q: cstring, out_prepared: ^Prepared_Statement) -> State ---
	destroy_prepare  :: proc(prepared: ^Prepared_Statement) ---
	prepare_error    :: proc(prepared: Prepared_Statement) -> cstring ---
	execute_prepared :: proc(prepared: Prepared_Statement, out_result: ^Result) -> State ---

	// Parameter binding (param_idx is 1-based).
	bind_boolean        :: proc(prepared: Prepared_Statement, param_idx: idx_t, val: bool) -> State ---
	bind_int64          :: proc(prepared: Prepared_Statement, param_idx: idx_t, val: i64) -> State ---
	bind_double         :: proc(prepared: Prepared_Statement, param_idx: idx_t, val: f64) -> State ---
	bind_timestamp      :: proc(prepared: Prepared_Statement, param_idx: idx_t, val: Timestamp) -> State ---
	bind_varchar_length :: proc(prepared: Prepared_Statement, param_idx: idx_t, val: cstring, length: idx_t) -> State ---
	bind_blob           :: proc(prepared: Prepared_Statement, param_idx: idx_t, data: rawptr, length: idx_t) -> State ---
	bind_null           :: proc(prepared: Prepared_Statement, param_idx: idx_t) -> State ---
}

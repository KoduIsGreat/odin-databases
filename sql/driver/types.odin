package driver

import "core:mem"
import "core:time"

// Value is the set of types that can be passed as query arguments
// or read from result columns. Drivers must accept and produce these.
//
// Values buffered by rows_next() point into driver-owned memory and are
// valid only until the next call to rows_next() or rows_close(). The
// user-facing sql.scan() clones string and []byte values so scanned
// results outlive the Rows.
//
// i128/u128 carry backend integers wider than i64 (e.g. DuckDB
// HUGEINT/UHUGEINT/UBIGINT) without precision loss. Custom_Value is the
// open extension point for column types the core does not model directly
// (see its doc comment) — it keeps this union closed to plain Odin types
// while letting drivers expose their own exotic types.
Value :: union {
	bool,
	i64,
	i128,
	u128,
	f64,
	string,
	[]byte,
	time.Time,
	Custom_Value,
	Null,
}

// Custom_Value is a self-contained cell for column types the core union does
// not model directly (e.g. DuckDB DECIMAL). The producing driver packs a small,
// trivially-copyable POD into `storage` and supplies `convert`, which writes the
// cell into a destination of the requested Odin type and returns true — or
// returns false if it cannot represent the cell as that type (the scan then
// reports a column/destination type mismatch).
//
// Because `storage` is inline bytes with no borrowed pointers, a Custom_Value
// copies freely and survives query_row detachment with no special handling — no
// clone/free dance, unlike borrowed string/[]byte values. The 16-byte-aligned
// [2]i128 storage holds PODs up to 32 bytes (enough for a 128-bit value plus
// metadata such as a decimal scale). Variable-size composites (LIST/STRUCT/MAP)
// are intentionally out of scope for this mechanism.
//
// `convert` receives a pointer to the storage, the destination field's typeid,
// the destination pointer, and an allocator to use for any allocation it must
// make (e.g. rendering to a string). Allocated results are owned by the caller,
// matching scan()'s clone-on-read semantics.
//
// `clone` and `free` are optional and handle payloads that reference external
// (borrowed) memory — e.g. a composite cell pointing into the driver's result
// buffer. When a Row is detached (query_row releases the connection before the
// caller scans), the core calls `clone` to deep-copy the payload into owned
// memory so it survives, and `free` to release that copy when the Row closes.
// Self-contained payloads that live entirely inside `storage` (DECIMAL, UUID,
// INTERVAL) leave both nil — copying the struct copies them.
Custom_Value :: struct {
	storage: [2]i128,
	convert: proc(payload: rawptr, dest_type: typeid, dest: rawptr, allocator: mem.Allocator) -> bool,
	clone:   proc(storage: ^[2]i128, allocator: mem.Allocator),
	free:    proc(storage: ^[2]i128, allocator: mem.Allocator),
}

// Null represents a SQL NULL value with an associated type hint
// so the driver knows what column type to expect.
Null :: struct {
	type_hint: typeid,
}

// Result holds the outcome of an exec (INSERT, UPDATE, DELETE).
Result :: struct {
	last_insert_id: i64,
	rows_affected:  i64,
}

// Column describes a column in a result set.
Column :: struct {
	name:     string,
	type_id:  typeid, // Odin type that best represents this column
	nullable: bool,
}

// Tx_Options controls transaction behavior.
Tx_Options :: struct {
	isolation: Isolation_Level,
	read_only: bool,
}

Isolation_Level :: enum {
	Default,
	Read_Uncommitted,
	Read_Committed,
	Repeatable_Read,
	Serializable,
}

// Error is returned by all sql operations. nil means success.
//
// All variants live here (in the driver contract package) because Odin
// unions are closed — every variant must be declared at the union's
// definition site. Drivers only ever produce Driver_Error values; the
// other variants are produced by the user-facing sql package, but they
// must be visible at the contract layer so the union type matches.
Error :: union {
	Driver_Error,
	Pool_Error,
	Arg_Error,
	Scan_Error,
}

Driver_Error :: struct {
	code:    int,
	message: string,
}

Pool_Error :: enum {
	Exhausted,
	Closed,
	Timeout,
}

Arg_Error :: enum {
	Invalid_Type,
	Wrong_Count,
}

Scan_Error_Kind :: enum {
	No_Row,
	Column_Count_Mismatch,
	Dest_Not_Pointer,
	Column_Type_Mismatch,
}

Scan_Error :: struct {
	kind:       Scan_Error_Kind,
	col_idx:    int,
	col_name:   string,
	dest_type:  typeid,
	value_type: typeid,
}

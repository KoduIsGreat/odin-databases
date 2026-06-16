package driver

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
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
	convert: proc(
		payload: rawptr,
		dest_type: typeid,
		dest: rawptr,
		allocator: mem.Allocator,
	) -> bool,
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
// definition site. Drivers produce Driver_Error for backend failures and
// Arg_Error when the caller's arguments don't match the query (only the driver
// knows a prepared statement's parameter count). Pool_Error and Scan_Error are
// produced by the user-facing sql package; all variants must be visible at the
// contract layer so the union type matches.
Error :: union {
	Driver_Error,
	Pool_Error,
	Arg_Error,
	Scan_Error,
}

// Error_Ctx is the diagnostic context the user-facing sql package attaches to
// an error on its way back to the caller: the SQL text that was being executed
// and the application call site that issued it (captured via #caller_location).
// It is embedded (`using`) in every struct variant of Error. Drivers never set
// it — annotation is the sql layer's job — so a zero ctx ("" / {}) simply means
// "not attached".
//
// `query` is BORROWED from the string the caller passed to exec/query/prepare;
// it is not cloned. It is valid as long as that string lives — always the case
// for the immediate error return, and for string literals (the common case)
// forever. Handles that outlive the call (Stmt, Rows) keep the same borrowed
// reference, so a caller that builds queries dynamically must keep the string
// alive for the handle's lifetime (already required today, since drivers may
// also reference it).
Error_Ctx :: struct {
	query: string,
	loc:   runtime.Source_Code_Location,
}

Driver_Error :: struct {
	using ctx: Error_Ctx,
	code:      int,
	message:   string,
}

Pool_Error :: enum {
	Exhausted,
	Closed,
	Timeout,
}

Arg_Error_Kind :: enum {
	Wrong_Count, // number of args supplied != number of query placeholders
	Invalid_Type, // an argument's type can't be bound as a query parameter
}

// Arg_Error reports a problem with the arguments passed to exec/query: either a
// count mismatch against the query's placeholders (Wrong_Count) or a value that
// can't be bound as a parameter (Invalid_Type). Drivers raise it after preparing
// the statement, since the placeholder count is only known then.
Arg_Error :: struct {
	using ctx:     Error_Ctx,
	kind:          Arg_Error_Kind,
	args_got:      int, // arguments supplied by the caller (Wrong_Count)
	args_expected: int, // placeholders the query declares (Wrong_Count)
	arg_idx:       int, // 0-based index of the offending argument (Invalid_Type)
	value_type:    typeid, // type of the offending argument (Invalid_Type)
}

Scan_Error_Kind :: enum {
	No_Row,
	Column_Count_Mismatch,
	Dest_Not_Pointer,
	Column_Type_Mismatch,
}

Scan_Error :: struct {
	using ctx:     Error_Ctx,
	kind:          Scan_Error_Kind,
	col_idx:       int,
	col_name:      string,
	dest_type:     typeid,
	value_type:    typeid,
	cols_got:      int,
	cols_expected: int,
}

// error_ctx returns the diagnostic context (query text + call site) attached
// to an error, or ok=false for variants that can't carry one (Pool_Error) or
// a nil error. A returned ctx may still be zero if nothing was attached.
error_ctx :: proc(u: Error) -> (ctx: Error_Ctx, ok: bool) {
	#partial switch e in u {
	case Driver_Error:
		return e.ctx, true
	case Arg_Error:
		return e.ctx, true
	case Scan_Error:
		return e.ctx, true
	}
	return {}, false
}

// error_query returns the SQL text attached to an error, or "" if none.
error_query :: proc(u: Error) -> string {
	ctx, _ := error_ctx(u)
	return ctx.query
}


// err_to_string renders an error for display, including the originating query
// and application call site when the sql layer attached them (see Error_Ctx).
// The result is allocated from the given allocator; the caller owns it.
err_to_string :: proc(u: Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	switch err in u {
	case Driver_Error:
		fmt.sbprintf(&b, "sql driver error code %v: %v", err.code, err.message)
	case Pool_Error:
		switch err {
		case .Exhausted:
			strings.write_string(&b, "sql pool exhausted")
		case .Closed:
			strings.write_string(&b, "sql pool closed")
		case .Timeout:
			strings.write_string(&b, "sql pool timeout")
		}
	case Scan_Error:
		switch err.kind {
		case .No_Row:
			strings.write_string(&b, "returned no rows")
		case .Column_Count_Mismatch:
			fmt.sbprintf(
				&b,
				"column count mismatch for column %v (idx %v), got %v, expected %v",
				err.col_name,
				err.col_idx,
				err.cols_got,
				err.cols_expected,
			)
		case .Dest_Not_Pointer:
			strings.write_string(&b, "sql dest not pointer")
		case .Column_Type_Mismatch:
			fmt.sbprintf(
				&b,
				"column type mismatch for column %v (idx %v), got %v, expected %v",
				err.col_name,
				err.col_idx,
				err.value_type,
				err.dest_type,
			)
		}
	case Arg_Error:
		switch err.kind {
		case .Wrong_Count:
			fmt.sbprintf(
				&b,
				"argument count mismatch: query has %v placeholder(s) but %v argument(s) were supplied",
				err.args_expected,
				err.args_got,
			)
		case .Invalid_Type:
			fmt.sbprintf(
				&b,
				"unsupported argument type %v at index %v (cannot be bound as a query parameter)",
				err.value_type,
				err.arg_idx,
			)
		}
	}
	if strings.builder_len(b) == 0 {
		strings.write_string(&b, "sql: unknown error")
	}
	if ctx, has_ctx := error_ctx(u); has_ctx {
		if ctx.query != "" {
			fmt.sbprintf(&b, "\n  query: %s", ctx.query)
		}
		if ctx.loc.file_path != "" {
			fmt.sbprintf(
				&b,
				"\n  at:    %s(%d:%d) in %s",
				ctx.loc.file_path,
				ctx.loc.line,
				ctx.loc.column,
				ctx.loc.procedure,
			)
		}
	}
	return strings.to_string(b)
}

package sql

import "core:time"

// Value is the set of types that can be passed as query arguments
// or read from result columns. Drivers must accept and produce these.
//
// Values buffered by next() point into driver-owned memory and are
// valid only until the next call to next() or close_rows(). However,
// scan() automatically clones string and []byte values using
// context.allocator, so scanned results remain valid after the
// Rows is closed. The caller owns the cloned memory.
Value :: union {
	bool,
	i64,
	f64,
	string,
	[]byte,
	time.Time,
	Null,
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

Scan_Error :: enum {
	No_Row,
	Column_Count_Mismatch,
	Dest_Not_Pointer,
}

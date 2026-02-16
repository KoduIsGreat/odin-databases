package sql

import "core:mem"

// Driver is a vtable of procedures that a database driver must implement.
// Driver authors fill in this struct with their concrete implementations.
// The sql package calls these through opaque handles — drivers cast
// handles to/from their own internal types.
Driver :: struct {
	// Connection lifecycle.
	// allocator is provided for driver-side Odin allocations (wrapper structs, etc).
	// The underlying C library manages its own memory separately.
	open:       proc(driver_data: rawptr, dsn: string, allocator: mem.Allocator) -> (Conn_Handle, Error),
	close_conn: proc(conn: Conn_Handle) -> Error,
	ping:       proc(conn: Conn_Handle) -> Error,
	reset:      proc(conn: Conn_Handle) -> Error,

	// Direct execution (fast path — no prepared statement)
	exec:  proc(conn: Conn_Handle, query: string, args: []Value) -> (Result, Error),
	query: proc(conn: Conn_Handle, query: string, args: []Value) -> (Rows_Handle, Error),

	// Prepared statements
	prepare:    proc(conn: Conn_Handle, query: string) -> (Stmt_Handle, Error),
	stmt_exec:  proc(stmt: Stmt_Handle, args: []Value) -> (Result, Error),
	stmt_query: proc(stmt: Stmt_Handle, args: []Value) -> (Rows_Handle, Error),
	stmt_close: proc(stmt: Stmt_Handle) -> Error,
	stmt_reset: proc(stmt: Stmt_Handle) -> Error,

	// Rows — values returned by rows_next have borrowed semantics.
	// They are valid only until the next rows_next call or rows_close.
	rows_columns: proc(rows: Rows_Handle) -> []Column,
	rows_next:    proc(rows: Rows_Handle, dest: []Value) -> bool,
	rows_close:   proc(rows: Rows_Handle) -> Error,

	// Transactions
	begin:       proc(conn: Conn_Handle, opts: Tx_Options) -> (Tx_Handle, Error),
	tx_commit:   proc(tx: Tx_Handle) -> Error,
	tx_rollback: proc(tx: Tx_Handle) -> Error,

	// Driver-owned opaque state (e.g. library handle, shared config).
	// Passed to open() so drivers can access shared resources.
	data: rawptr,
}

// Opaque handles — the sql package never looks inside these.
// Drivers cast to/from their own concrete types.
Conn_Handle :: distinct rawptr
Stmt_Handle :: distinct rawptr
Rows_Handle :: distinct rawptr
Tx_Handle   :: distinct rawptr

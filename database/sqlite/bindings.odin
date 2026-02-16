package sqlite

import "core:c"

// Minimal SQLite3 C bindings — only what the driver needs.

foreign import sqlite3lib "system:sqlite3"

sqlite3      :: struct {}
sqlite3_stmt :: struct {}

SQLITE_OK         :: 0
SQLITE_ERROR      :: 1
SQLITE_BUSY       :: 5
SQLITE_CONSTRAINT :: 19
SQLITE_MISUSE     :: 21
SQLITE_ROW        :: 100
SQLITE_DONE       :: 101

// Column types
SQLITE_INTEGER :: 1
SQLITE_FLOAT   :: 2
SQLITE_TEXT    :: 3
SQLITE_BLOB    :: 4
SQLITE_NULL    :: 5

// Special destructor values for bind functions.
// SQLITE_TRANSIENT tells SQLite to make its own copy of the data.
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite3lib {
	// Database lifecycle
	open     :: proc(filename: cstring, ppDb: ^^sqlite3) -> c.int ---
	close    :: proc(db: ^sqlite3) -> c.int ---

	// Error reporting
	errmsg   :: proc(db: ^sqlite3) -> cstring ---
	errcode  :: proc(db: ^sqlite3) -> c.int ---

	// Statement lifecycle
	prepare_v2 :: proc(db: ^sqlite3, zSql: [^]u8, nByte: c.int, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> c.int ---
	step       :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	finalize   :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	reset      :: proc(stmt: ^sqlite3_stmt) -> c.int ---

	// Bind parameters (1-indexed)
	bind_int64  :: proc(stmt: ^sqlite3_stmt, idx: c.int, value: i64) -> c.int ---
	bind_double :: proc(stmt: ^sqlite3_stmt, idx: c.int, value: f64) -> c.int ---
	bind_text   :: proc(stmt: ^sqlite3_stmt, idx: c.int, text: [^]u8, nByte: c.int, destructor: rawptr) -> c.int ---
	bind_blob   :: proc(stmt: ^sqlite3_stmt, idx: c.int, data: [^]u8, nByte: c.int, destructor: rawptr) -> c.int ---
	bind_null   :: proc(stmt: ^sqlite3_stmt, idx: c.int) -> c.int ---

	// Column accessors (0-indexed)
	column_count    :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	column_name     :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> cstring ---
	column_type     :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> c.int ---
	column_decltype :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> cstring ---
	column_int64  :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> i64 ---
	column_double :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> f64 ---
	column_text   :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> [^]u8 ---
	column_blob   :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> [^]u8 ---
	column_bytes  :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> c.int ---

	// Result metadata
	changes             :: proc(db: ^sqlite3) -> c.int ---
	last_insert_rowid   :: proc(db: ^sqlite3) -> i64 ---

	// Simple execution
	exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
}

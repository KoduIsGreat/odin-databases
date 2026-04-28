// Hand-written replacements for SQLITE_STATIC / SQLITE_TRANSIENT, which are
// defined in sqlite3.h as casts of integer literals to function pointers — a
// pattern obg can't translate. They're sentinel values never actually called
// by SQLite; passing them into sqlite3_bind_text/blob/etc. instructs SQLite
// how to treat the buffer.
//
// They're package-level `var`s (not constants) because Odin doesn't allow
// `transmute` in constant expressions. SQLite never dereferences them, so
// rodata-style initialization is fine.

@(private="file")
_transient_init :: proc "contextless" () -> destructor_type {
	return transmute(destructor_type)(~uintptr(0))
}

STATIC:    destructor_type = nil
TRANSIENT: destructor_type = _transient_init()

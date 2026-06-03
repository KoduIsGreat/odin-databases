// quickstart — the core database:sql API with the SQLite driver.
//
// Covers: opening a DB with a driver, exec, transactions + prepared
// statements, query_row, and scanning rows into structs (reflective and
// positional). No code generation — see the codegen examples for that.
//
// Run: just run-example quickstart   (or: odin run examples/quickstart)
package quickstart

import "core:fmt"
import vmem "core:mem/virtual"
import "core:time"

import sqlite "database:drivers/sqlite"
import sql "database:sql"

User :: struct {
	id:         i64,
	name:       string,
	age:        int,
	created_at: time.Time,
}

// seed creates the table and inserts a few users inside a transaction, reusing
// one prepared statement for every row.
seed :: proc(db: ^sql.DB) -> sql.Error {
	sql.exec(
		db,
		"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, created_at DATETIME)",
	) or_return

	tx := sql.begin(db) or_return
	stmt, perr := sql.prepare(&tx, "INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)")
	if perr != nil {
		sql.rollback(&tx)
		return perr
	}
	defer sql.stmt_close(&stmt)

	now := time.now()
	rows := [?][3]sql.Value {
		{"Alice", i64(30), now},
		{"Bob", i64(25), now},
		{"Carol", i64(41), now},
	}
	for &r in rows {
		if _, err := sql.stmt_exec(&stmt, r[:]); err != nil {
			sql.rollback(&tx)
			return err
		}
	}
	return sql.commit(&tx)
}

main :: proc() {
	// Use an arena for scan output (cloned strings/bytes); pool internals use
	// the allocator passed to open().
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintfln("arena: %v", err)
		return
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	db, open_err := sql.open(&sqlite.driver, ":memory:")
	if open_err != nil {
		fmt.eprintfln("open: %v", open_err)
		return
	}
	defer sql.close(db)

	if err := seed(db); err != nil {
		fmt.eprintfln("seed: %v", err)
		return
	}

	// query_row: a single-row convenience that detaches and frees its conn.
	fmt.println("--- query_row ---")
	{
		row := sql.query_row(db, "SELECT * FROM users WHERE name = ?", "Alice")
		defer sql.close_row(&row)
		u: User
		if err := sql.scan(&row, &u); err != nil {
			fmt.eprintfln("scan: %v", err)
			return
		}
		fmt.printfln("  %v is %v", u.name, u.age)
	}

	// query + reflective scan: column names matched to struct field names.
	fmt.println("\n--- scan whole struct (reflective) ---")
	{
		rows, err := sql.query(db, "SELECT * FROM users ORDER BY age")
		if err != nil {
			fmt.eprintfln("query: %v", err)
			return
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			u: User
			if serr := sql.scan(&rows, &u); serr != nil {
				fmt.eprintfln("scan: %v", serr)
				return
			}
			fmt.printfln("  id=%v  name=%v  age=%v", u.id, u.name, u.age)
		}
		// next() returns false for both a clean end-of-rows and a mid-stream
		// failure, so check rows_err afterward (nil = fully consumed).
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("rows: %v", rerr)
			return
		}
	}

	// query + positional scan: bind columns to variables in column order.
	fmt.println("\n--- scan into variables (positional) ---")
	{
		rows, err := sql.query(db, "SELECT name, age FROM users WHERE age >= ?", i64(30))
		if err != nil {
			fmt.eprintfln("query: %v", err)
			return
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			name: string
			age: int
			if serr := sql.scan(&rows, &name, &age); serr != nil {
				fmt.eprintfln("scan: %v", serr)
				return
			}
			fmt.printfln("  %v (%v)", name, age)
		}

		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("rows err: %v", rerr)
			return
		}
	}
}

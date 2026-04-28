package basic

import sql "../../../database/sql"
import sb "../../../database/sqlbuilder"
import sqlite3 "../../../database/sqlite"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:time"

User :: struct {
	id:         i64,
	name:       string,
	age:        int,
	created_at: time.Time,
}

init_db :: proc(db: ^sql.DB) -> sql.Error {
	_ = sql.exec(
		db,
		"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, created_at DATETIME)",
	) or_return
	tx := sql.begin(db) or_return
	stmt := sql.prepare(&tx, "INSERT INTO users (name, age, created_at) VALUES(?, ?, ?)") or_return

	now := time.now()

	res, err := sql.stmt_exec(&stmt, {"Adam", i64(35), now})
	sql.stmt_exec(&stmt, {"Joe", i64(37), now})
	sql.stmt_exec(&stmt, {"Mark", i64(36), now})
	sql.stmt_exec(&stmt, {"gamer", i64(32), now})

	if tx_err := sql.commit(&tx); tx_err != nil {
		return tx_err
	}

	return nil
}

main :: proc() {

	// Arena for scan allocations (cloned strings/bytes).
	// Pool internals use the allocator passed to open().
	pool_arena: vmem.Arena
	if err := vmem.arena_init_growing(&pool_arena); err != nil {
		fmt.eprintfln("arena err: %v", err)
		return
	}
	defer vmem.arena_destroy(&pool_arena)
	context.allocator = vmem.arena_allocator(&pool_arena)

	db, open_err := sql.open(&sqlite3.driver, ":memory:")
	if open_err != nil {
		fmt.eprintfln("open: %v", open_err)
		return
	}
	defer sql.close(db)
	if err := init_db(db); err != nil {
		fmt.eprintfln("init_db err: %v", err)
		return
	}

	fmt.println("--- single user ---")
	{
		row := sql.query_row(db, "SELECT * FROM users WHERE name = ?", "Adam")
		user: User
		if err := sql.scan(&row, &user); err != nil {
			fmt.eprintfln("query_row err: %v", err)
			return
		}
		fmt.printfln(
			"  id=%v  name=%v  age=%v  created_at=%v",
			user.id,
			user.name,
			user.age,
			user.created_at,
		)
	}

	fmt.println("\n--- users into slice using positions ---")
	{
		rows, err := sql.query(db, "SELECT id, name, age, created_at FROM users")
		if err != nil {
			fmt.eprintfln("query err: %v", err)
			return
		}
		defer sql.close_rows(&rows)

		users: [dynamic]User
		defer delete(users)

		for sql.next(&rows) {
			user: User
			if scan_err := sql.scan(&rows, &user.id, &user.name, &user.age, &user.created_at);
			   scan_err != nil {
				fmt.eprintfln("scan err: %v", scan_err)
				return
			}
			append(&users, user)
		}

		for u in users {
			fmt.printfln("  id=%v  name=%v  age=%v", u.id, u.name, u.age)
		}
	}

	fmt.println("\n--- users into slice using reflection ---")
	{
		rows, err := sql.query(db, "SELECT * FROM users")
		if err != nil {
			fmt.eprintfln("query err: %v", err)
			return
		}
		defer sql.close_rows(&rows)

		users: [dynamic]User
		defer delete(users)

		for sql.next(&rows) {
			user: User
			if scan_err := sql.scan(&rows, &user); scan_err != nil {
				fmt.eprintfln("scan err: %v", scan_err)
				return
			}
			append(&users, user)
		}

		for u in users {
			fmt.printfln("  id=%v  name=%v  age=%v", u.id, u.name, u.age)
		}
	}


	fmt.println("\n--- sql builder ---")
	{
		b: sb.Builder
		sb.init(&b)
		defer sb.destroy(&b)

		sb.select(&b, "id", "name", "age")
		sb.from(&b, "users")
		sb.where_clause(&b, "age >= ?", i64(35))
		sb.where_clause(&b, "name != ?", "gamer")
		sb.order_by(&b, "name")

		query, args := sb.to_query(&b)
		fmt.printfln("  query: %v", query)
		fmt.printfln("  args:  %v", args)

		rows, err := sql.query(db, query, ..args)
		if err != nil {
			fmt.eprintfln("query err: %v", err)
			return
		}
		defer sql.close_rows(&rows)

		for sql.next(&rows) {
			user: User
			if scan_err := sql.scan(&rows, &user.id, &user.name, &user.age);
			   scan_err != nil {
				fmt.eprintfln("scan err: %v", scan_err)
				return
			}
			fmt.printfln("  id=%v  name=%v  age=%v", user.id, user.name, user.age)
		}
	}

	fmt.println("\n--- error condition ---")
	{
		WrongUser :: struct {
			id:         i64,
			name:       string,
			age:        f64,
			created_at: time.Time,
		}
		rows, err := sql.query(db, "SELECT * FROM users")
		if err != nil {
			fmt.eprintfln("query err: %v", err)
			return
		}
		defer sql.close_rows(&rows)

		users: [dynamic]WrongUser
		defer delete(users)

		for sql.next(&rows) {
			user: WrongUser
			if scan_err := sql.scan(&rows, &user.id, &user.name, &user.age, &user.created_at);
			   scan_err != nil {
				fmt.eprintfln("scan err: %v", scan_err)
				return
			}
			append(&users, user)
		}

		for u in users {
			fmt.printfln("  id=%v  name=%v  age=%v", u.id, u.name, u.age)
		}
	}
}

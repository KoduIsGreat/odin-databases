package main

import "core:fmt"
import "core:time"

import "database/sql"
import "database/sqlite"

User :: struct {
	id:         i64,
	name:       string,
	age:        int,
	created_at: time.Time,
}

main :: proc() {
	db, open_err := sql.open(&sqlite.driver, ":memory:")
	if open_err != nil {
		fmt.eprintfln("open: %v", open_err)
		return
	}
	defer sql.close(db)

	_, err := sql.exec(
		db,
		"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, created_at DATETIME)",
	)
	if err != nil {
		fmt.eprintfln("create table: %v", err)
		return
	}

	now := time.now()
	_, err = sql.exec(
		db,
		"INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)",
		"Alice",
		i64(30),
		now,
	)
	if err != nil {fmt.eprintfln("insert: %v", err);return}
	_, err = sql.exec(
		db,
		"INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)",
		"Bob",
		i64(25),
		now,
	)
	if err != nil {fmt.eprintfln("insert: %v", err);return}
	_, err = sql.exec(
		db,
		"INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)",
		"Charlie",
		i64(35),
		now,
	)
	if err != nil {fmt.eprintfln("insert: %v", err);return}

	// Scan into struct
	fmt.println("--- scan into struct ---")
	{
		rows, qerr := sql.query(db, "SELECT id, name, age, created_at FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		for sql.next(&rows) {
			user: User
			sql.scan(&rows, &user)
			yr, mo, dy := time.date(user.created_at)
			hr, mn, sc := time.clock(user.created_at)
			fmt.printfln(
				"  id=%v  name=%v  age=%v  created_at=%4d-%02d-%02d %02d:%02d:%02d",
				user.id,
				user.name,
				user.age,
				yr,
				int(mo),
				dy,
				hr,
				mn,
				sc,
			)
		}
	}

	// Scan with a partial struct (fewer fields than columns)
	fmt.println("\n--- scan partial struct ---")
	{
		NameOnly :: struct {
			name: string,
		}

		rows, qerr := sql.query(db, "SELECT id, name, age FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		for sql.next(&rows) {
			n: NameOnly
			sql.scan(&rows, &n)
			fmt.printfln("  name=%v", n.name)
		}
	}

	// Scan with prepared statement
	fmt.println("\n--- scan with prepared stmt ---")
	{
		conn, cerr := sql.checkout(db)
		if cerr != nil {fmt.eprintfln("checkout: %v", cerr);return}
		defer sql.checkin(&conn)

		stmt, perr := sql.prepare(&conn, "SELECT name, age FROM users WHERE age > ?")
		if perr != nil {fmt.eprintfln("prepare: %v", perr);return}
		defer sql.close_stmt(&stmt)

		srows, serr := sql.stmt_query(&stmt, {i64(26)})
		if serr != nil {fmt.eprintfln("stmt_query: %v", serr);return}
		defer sql.close_rows(&srows)

		for sql.next(&srows) {
			user: User
			sql.scan(&srows, &user)
			fmt.printfln("  name=%v  age=%v", user.name, user.age)
		}
	}

	// Scan single row
	fmt.println("\n--- scan single row ---")
	{
		rows, qerr := sql.query(db, "SELECT name, age FROM users WHERE id = ?", i64(1))
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		if sql.next(&rows) {
			user: User
			sql.scan(&rows, &user)
			fmt.printfln("  name=%v  age=%v", user.name, user.age)
		}
	}

	// Scan into individual variables
	fmt.println("\n--- scan_values ---")
	{
		rows, qerr := sql.query(db, "SELECT name, age FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		for sql.next(&rows) {
			name: string
			age: int
			sql.scan(&rows, &name, &age)
			fmt.printfln("  name=%v  age=%v", name, age)
		}
	}

	fmt.println("\n--- scan into struct fields ---")
	{
		rows, qerr := sql.query(db, "SELECT id, name, age, created_at FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		if sql.next(&rows) {
			user: User
			sql.scan(&rows, &user.id, &user.name, &user.age, &user.created_at)
			fmt.printfln(
				"id=%v  name=%v  age=%v  created_at=%v",
				user.id,
				user.name,
				user.age,
				user.created_at,
			)
		}
	}

	// Single value scan
	fmt.println("\n--- scan single value ---")
	{
		rows, qerr := sql.query(db, "SELECT count(*) FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		if sql.next(&rows) {
			total: i64
			sql.scan(&rows, &total)
			fmt.printfln("  total=%v", total)
		}
	}

	// Transaction + scan to verify
	fmt.println("\n--- transaction + verify ---")
	{
		tx, terr := sql.begin(db)
		if terr != nil {fmt.eprintfln("begin: %v", terr);return}

		_, err = sql.exec(
			&tx,
			"INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)",
			"Diana",
			i64(28),
			now,
		)
		if err != nil {sql.rollback(&tx);fmt.eprintfln("tx insert: %v", err);return}
		sql.commit(&tx)
	}
	{
		rows, qerr := sql.query(db, "SELECT count(*) as total FROM users")
		if qerr != nil {fmt.eprintfln("query: %v", qerr);return}
		defer sql.close_rows(&rows)

		Count :: struct {
			total: i64,
		}
		if sql.next(&rows) {
			c: Count
			sql.scan(&rows, &c)
			fmt.printfln("  total users: %v", c.total)
		}
	}
}

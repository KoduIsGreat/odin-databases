package main

import "core:fmt"
import "core:time"
import "database:dburl"
import "database:sql"


//+sql:scan
User :: struct {
	id:         i64,
	name:       string,
	age:        int,
	created_at: time.Time,
}

err_to_string :: proc {
	dburl.error_to_string,
	sql.err_to_string,
}

main :: proc() {
	db, err := dburl.open_url("sqlite://:memory:")
	if err != nil {
		fmt.println(err_to_string(err))
		return
	}
	defer sql.close(db)

	_, cerr := sql.exec(
		db,
		"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, created_at DATETIME)",
	)
	if cerr != nil {
		fmt.eprintfln("create table: %v", err_to_string(cerr))
		return
	}
	now := time.now()
	_, ierr := sql.exec(
		db,
		"INSERT INTO users (name, age, created_at) VALUES (?, ?, ?)",
		"Alice",
		i64(30),
		now,
	)
	if ierr != nil {
		fmt.eprintfln("insert: %v", err_to_string(ierr))
		return
	}

	// Scan into struct
	fmt.println("--- scan into struct ---")
	{
		users := make([dynamic]User, context.temp_allocator)
		rows, qerr := sql.query(db, "SELECT id, name, age, created_at FROM users")
		if qerr != nil {
			fmt.eprintfln("query: %v", qerr)
			return
		}
		defer sql.rows_close(&rows)

		for sql.next(&rows) {
			user: User
			if err := sql.scan(&rows, &user.id, &user.name, &user.age, &user.created_at);
			   err != nil {
				fmt.eprintfln("scan: %v", err_to_string(err))
				return
			}
			append(&users, user)
		}
		// next() returns false for both clean EOF and a mid-stream failure, so
		// check rows_err after every loop — otherwise a truncated result reads
		// as complete.
		if rerr := sql.rows_err(&rows); rerr != nil {
			fmt.eprintfln("rows: %v", err_to_string(rerr))
			return
		}
		for user in users {
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
}

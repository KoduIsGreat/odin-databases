package main

import "core:fmt"

import duckdb "database:drivers/duckdb"
import sql "database:sql"

main :: proc() {
	db, open_err := sql.open(&duckdb.driver, ":memory:")
	if open_err != nil {

		fmt.println(sql.err_to_string(open_err))
		return
	}
	defer sql.close(db)
	res, err := sql.exec(db, "CREATE TABLE users (id INTEGER, name VARCHAR, age INTEGER)")
	if err != nil {
		fmt.println(sql.err_to_string(err))
		return
	}
	q := "INSERT INTO users VALUES (?, ?, ?)"
	if _, err := sql.exec(db, q, i64(1), "Alice", i64(30)); err != nil {
		fmt.println(sql.err_to_string(err))
		return
	}

	q1 := "SELECT id, name, age FROM users WHERE age > 0"
	rows, rerr := sql.query(db, q1, i64(18))
	if rerr != nil {
		fmt.println(sql.err_to_string(rerr))
		return
	}
	defer sql.rows_close(&rows)

	for sql.next(&rows) {
		id: i64
		name: string
		age: i64
		if err := sql.scan(&rows, &id, &name, &age); err != nil {
			fmt.println(err)
			return
		}
		fmt.printfln("  id=%v  name=%v  age=%v", id, name, age)
	}
	if rerr := sql.rows_err(&rows); rerr != nil {
		fmt.println(rerr)
		return
	}
}

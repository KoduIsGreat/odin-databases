package main

import "core:fmt"
import "core:strings"

import ddb "../duckdb"

main :: proc() {
	db: ddb.Database
	if ddb.open(":memory:", &db) != .Success {
		fmt.eprintln("open failed")
		return
	}
	defer ddb.close(&db)

	con: ddb.Connection
	if ddb.connect(db, &con) != .Success {
		fmt.eprintln("connect failed")
		return
	}
	defer ddb.disconnect(&con)

	run :: proc(con: ddb.Connection, q: string) {
		cq := strings.clone_to_cstring(q);defer delete(cq)
		res: ddb.Result
		if ddb.query(con, cq, &res) != .Success {
			fmt.eprintln("query failed:", ddb.result_error(&res))
		}
		ddb.destroy_result(&res)
	}

	run(con, "CREATE TABLE t (id INTEGER, name VARCHAR)")
	run(con, "INSERT INTO t VALUES (1, 'alice'), (2, 'bob'), (3, 'carol')")

	res: ddb.Result
	if ddb.query(con, "SELECT id, name FROM t ORDER BY id", &res) != .Success {
		fmt.eprintln("select failed:", ddb.result_error(&res))
		return
	}
	defer ddb.destroy_result(&res)

	nrows := ddb.row_count(&res)
	for row in 0 ..< nrows {
		id := ddb.value_int64(&res, 0, row)
		name := ddb.value_varchar(&res, 1, row)
		fmt.printfln("  row: id=%d name=%s", id, name)
		ddb.free(rawptr(name))
	}
}

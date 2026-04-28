package main

import sql "../sqlite"
import "core:fmt"
import "core:strings"

main :: proc() {
	fmt.println("SQLite version:", sql.libversion())

	db: ^sql.sqlite3
	if rc := sql.open(":memory:", &db); rc != sql.OK {
		fmt.eprintln("open failed:", rc)
		return
	}
	defer sql.close(db)

	exec :: proc(db: ^sql.sqlite3, q: string) {
		cq := strings.clone_to_cstring(q);defer delete(cq)
		errmsg: cstring
		if rc := sql.exec(db, cq, nil, nil, &errmsg); rc != sql.OK {
			fmt.eprintln("exec failed:", rc, errmsg)
			sql.free(rawptr(errmsg))
		}
	}

	exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);")
	exec(db, "INSERT INTO t (name) VALUES ('alice'), ('bob'), ('carol');")

	stmt: ^sql.stmt
	if rc := sql.prepare_v2(db, "SELECT id, name FROM t ORDER BY id;", -1, &stmt, nil);
	   rc != sql.OK {
		fmt.eprintln("prepare failed:", rc, sql.errmsg(db))
		return
	}
	defer sql.finalize(stmt)


	for sql.step(stmt) == sql.ROW {
		id := sql.column_int(stmt, 0)
		name := cstring(sql.column_text(stmt, 1))
		fmt.printfln("  row: id=%d name=%s", id, name)
	}
}

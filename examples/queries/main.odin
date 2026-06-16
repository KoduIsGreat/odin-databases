// queries — demonstrates querygen: typed data-access procedures generated from
// annotated `.sql` files.
//
// queries.gen.odin in this package is generated from sql/queries.sql by
// *describing* each query against a throwaway SQLite database (see schema.sql):
// querygen runs the query, reads the result column types from the driver, and
// emits a typed proc + result struct per query. `-- arg:` lines supply the
// parameter types (SQLite cannot report those statically).
//
// Regenerate with `just gen-queries` after editing sql/queries.sql.
//
// Note (this slice): result columns map to their base Odin type, so the example
// inserts non-NULL emails — querygen does not yet emit Maybe(T) for nullable
// columns (SQLite's describe can't report nullability).
//
// Run: just run-example queries   (or: odin run examples/queries)
package queries

import "core:fmt"

import sqlite "database:drivers/sqlite"
import sql "database:sql"

main :: proc() {
	db, err := sql.open(&sqlite.driver, ":memory:")
	if err != nil {fmt.eprintfln("open: %v", err);return}
	defer sql.close(db)

	// A live schema matching schema.sql.
	_, err = sql.exec(
		db,
		"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, age INTEGER)",
	)
	if err != nil {fmt.eprintfln("create: %v", err);return}

	// Seed via the generated :exec proc.
	seed := [?]struct {
		name:  string,
		email: string,
		age:   i64,
	}{{"Alice", "alice@example.com", 30}, {"Bob", "bob@example.com", 25}, {"Carol", "carol@example.com", 41}}
	for s in seed {
		if _, e := CreateUser(db, s.name, s.email, s.age); e != nil {
			fmt.eprintfln("CreateUser: %v", e)
			return
		}
	}

	// :one — a single typed row.
	alice, e1 := GetUserByID(db, 1)
	if e1 != nil {fmt.eprintfln("GetUserByID: %v", e1);return}
	fmt.printfln(
		":one  GetUserByID(1) -> id=%v name=%q email=%q age=%v",
		alice.id,
		alice.name,
		alice.email,
		alice.age,
	)

	// :many — a typed slice (caller owns it).
	adults, e2 := ListUsersByMinAge(db, 30)
	if e2 != nil {fmt.eprintfln("ListUsersByMinAge: %v", e2);return}
	defer delete(adults)
	fmt.printfln(":many ListUsersByMinAge(30) -> %d row(s):", len(adults))
	for u in adults {
		fmt.printfln("        id=%v name=%q age=%v", u.id, u.name, u.age)
	}
}

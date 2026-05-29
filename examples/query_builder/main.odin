// query_builder — the typed sqlbuilder driven by generated descriptors.
//
// The two structs below are annotated with BOTH generators:
//   //+sql:scan        → scangen emits concrete scan_User / scan_Post procs
//   //+sql:table <t>    → schemagen (struct mode) emits the Users / Posts
//                         column descriptors used to build typed queries
//
// So queries reference generated identifiers (Users.age, Posts.title): a
// mistyped column won't compile, predicate/insert values are type-checked, and
// scanning uses the fast generated scanner. Regenerate with:
//   just gen-query-builder
//
// Run: just run-example query_builder   (or: odin run examples/query_builder)
package query_builder

import "core:fmt"

import sql "../../database/sql"
import sb "../../database/sqlbuilder"
import sqlite "../../drivers/sqlite"

//+sql:scan
//+sql:table users
User :: struct {
	id:   i64,
	name: string,
	age:  int,
}

//+sql:scan
//+sql:table posts
Post :: struct {
	id:      i64,
	user_id: i64,
	title:   string,
}

seed :: proc(db: ^sql.DB) -> sql.Error {
	sql.exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)") or_return
	sql.exec(
		db,
		"CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)",
	) or_return

	// Typed INSERT: each bind() checks the value against the column's type.
	people := [?]struct {
		name: string,
		age:  int,
	}{{"Alice", 30}, {"Bob", 25}, {"Carol", 41}}
	for p in people {
		b: sb.Builder
		sb.init(&b)
		defer sb.destroy(&b)
		sb.insert_into(&b, Users, sb.bind(Users.name, p.name), sb.bind(Users.age, p.age))
		q, args := sb.to_query(&b)
		sql.exec(db, q, ..args) or_return
	}

	posts := [?]struct {
		user_id: i64,
		title:   string,
	}{{1, "Hello from Alice"}, {3, "Carol writes too"}}
	for p in posts {
		b: sb.Builder
		sb.init(&b)
		defer sb.destroy(&b)
		sb.insert_into(&b, Posts, sb.bind(Posts.user_id, p.user_id), sb.bind(Posts.title, p.title))
		q, args := sb.to_query(&b)
		sql.exec(db, q, ..args) or_return
	}
	return nil
}

main :: proc() {
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

	// SELECT ... WHERE ... ORDER BY, scanning into the generated User struct.
	fmt.println("--- select + where + order ---")
	{
		b: sb.Builder
		sb.init(&b)
		defer sb.destroy(&b)

		sb.select(&b, Users.id, Users.name, Users.age)
		sb.from(&b, Users)
		sb.where_(&b, sb.ge(Users.age, 30))
		sb.order_by(&b, sb.desc(Users.age))

		q, args := sb.to_query(&b)
		fmt.printfln("  %s", q)

		rows, err := sql.query(db, q, ..args)
		if err != nil {fmt.eprintfln("query: %v", err);return}
		defer sql.close_rows(&rows)
		for sql.next(&rows) {
			u: User
			scan(&rows, &u) // concrete scan_User from scangen
			fmt.printfln("    id=%v  name=%v  age=%v", u.id, u.name, u.age)
		}
	}

	// JOIN with a typed ON predicate (col_eq requires both sides share a type).
	fmt.println("\n--- join ---")
	{
		b: sb.Builder
		sb.init(&b)
		defer sb.destroy(&b)

		sb.select(&b, Users.name, Posts.title)
		sb.from(&b, Users)
		sb.join(&b, Posts, sb.col_eq(Posts.user_id, Users.id))

		q, args := sb.to_query(&b)
		fmt.printfln("  %s", q)

		rows, err := sql.query(db, q, ..args)
		if err != nil {fmt.eprintfln("query: %v", err);return}
		defer sql.close_rows(&rows)
		for sql.next(&rows) {
			name, title: string
			scan(&rows, &name, &title)
			fmt.printfln("    %v: %q", name, title)
		}
	}

	// UPDATE ... SET ... WHERE, then DELETE ... WHERE.
	fmt.println("\n--- update + delete ---")
	{
		{
			b: sb.Builder
			sb.init(&b)
			defer sb.destroy(&b)
			sb.update(&b, Users)
			sb.set(&b, Users.age, 26)
			sb.where_(&b, sb.eq(Users.name, "Bob"))
			q, args := sb.to_query(&b)
			res, err := sql.exec(db, q, ..args)
			if err != nil {fmt.eprintfln("update: %v", err);return}
			fmt.printfln("  updated %v row(s)", res.rows_affected)
		}
		{
			b: sb.Builder
			sb.init(&b)
			defer sb.destroy(&b)
			sb.delete_from(&b, Users)
			sb.where_(&b, sb.lt(Users.age, 30))
			q, args := sb.to_query(&b)
			res, err := sql.exec(db, q, ..args)
			if err != nil {fmt.eprintfln("delete: %v", err);return}
			fmt.printfln("  deleted %v row(s)", res.rows_affected)
		}
	}
}

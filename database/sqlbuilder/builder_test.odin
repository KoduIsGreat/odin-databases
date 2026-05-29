package sqlbuilder

import "core:testing"

@(test)
test_select_with_where_and_order :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b, "id", "name")
	from(&b, "users")
	where_clause(&b, "age >= ?", i64(18))
	where_clause(&b, "name != ?", "bot")
	order_by(&b, "name")
	limit(&b, 10)

	q, args := to_query(&b)
	testing.expect_value(t, q, "SELECT id, name FROM users WHERE age >= ? AND name != ? ORDER BY name LIMIT 10")
	testing.expect_value(t, len(args), 2)
}

@(test)
test_select_star :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b)
	from(&b, "users")

	q, _ := to_query(&b)
	testing.expect_value(t, q, "SELECT * FROM users")
}

@(test)
test_multi_join :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b, "u.id", "p.title")
	from(&b, "users u")
	join(&b, "posts p", "p.user_id = u.id")
	join(&b, "comments c", "c.post_id = p.id")
	where_clause(&b, "u.id = ?", i64(1))

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT u.id, p.title FROM users u JOIN posts p ON p.user_id = u.id JOIN comments c ON c.post_id = p.id WHERE u.id = ?",
	)
	testing.expect_value(t, len(args), 1)
}

@(test)
test_insert_values :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	insert_into(&b, "users", "name", "age")
	values(&b, "alice", i64(30))

	q, args := to_query(&b)
	testing.expect_value(t, q, "INSERT INTO users (name, age) VALUES (?, ?)")
	testing.expect_value(t, len(args), 2)
}

@(test)
test_update_set_multi :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	update(&b, "users")
	set_cols(&b, "name = ?", "bob")
	set_cols(&b, "age = ?", i64(25))
	where_clause(&b, "id = ?", i64(1))

	q, args := to_query(&b)
	testing.expect_value(t, q, "UPDATE users SET name = ?, age = ? WHERE id = ?")
	testing.expect_value(t, len(args), 3)
}

@(test)
test_reset_clears_all_counts :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	// First query — exercise all counters.
	select(&b)
	from(&b, "a")
	join(&b, "b", "b.id = a.id")
	where_clause(&b, "x = 1")

	reset(&b)

	// Second query should start clean — no leftover " AND " on the first
	// where_clause, no leftover join_count quirks.
	select(&b)
	from(&b, "c")
	where_clause(&b, "y = 2")

	q, _ := to_query(&b)
	testing.expect_value(t, q, "SELECT * FROM c WHERE y = 2")
}

@(test)
test_ident_validation :: proc(t: ^testing.T) {
	testing.expect(t,  ident("name"),       "name should pass")
	testing.expect(t,  ident("user_id"),    "user_id should pass")
	testing.expect(t,  ident("users.id"),   "users.id should pass")
	testing.expect(t,  ident("u1"),         "u1 should pass")
	testing.expect(t, !ident(""),           "empty should fail")
	testing.expect(t, !ident("1abc"),       "digit-prefixed should fail")
	testing.expect(t, !ident("a;DROP"),     "semicolons forbidden")
	testing.expect(t, !ident("a.b.c"),      "two dots forbidden")
	testing.expect(t, !ident(".name"),      "leading dot forbidden")
	testing.expect(t, !ident("name."),      "trailing dot forbidden")
	testing.expect(t, !ident("name space"), "spaces forbidden")
}

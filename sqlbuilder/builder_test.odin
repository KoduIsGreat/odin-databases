package sqlbuilder

import "core:testing"

// --- Test fixtures: a hand-written stand-in for what schemagen emits. ---

Users := struct {
	_info: Table_Info,
	id:    Column(i64),
	name:  Column(string),
	age:   Column(int),
} {
	_info = {name = "users"},
	id = {base = {table = "users", name = "id", type_id = i64}},
	name = {base = {table = "users", name = "name", type_id = string}},
	age = {base = {table = "users", name = "age", type_id = int}},
}

Posts := struct {
	_info:   Table_Info,
	id:      Column(i64),
	user_id: Column(i64),
	title:   Column(string),
} {
	_info = {name = "posts"},
	id = {base = {table = "posts", name = "id", type_id = i64}},
	user_id = {base = {table = "posts", name = "user_id", type_id = i64}},
	title = {base = {table = "posts", name = "title", type_id = string}},
}

// --- Typed layer ---

@(test)
test_typed_select_where_order :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b, Users.id, Users.name)
	from(&b, Users)
	where_(&b, ge(Users.age, 18))
	where_(&b, ne(Users.name, "bot"))
	order_by(&b, asc(Users.name))
	limit(&b, 10)

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT users.id, users.name FROM users WHERE users.age >= ? AND users.name != ? ORDER BY users.name LIMIT 10",
	)
	testing.expect_value(t, len(args), 2)
}

@(test)
test_typed_select_star :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b)
	from(&b, Users)

	q, _ := to_query(&b)
	testing.expect_value(t, q, "SELECT * FROM users")
}

@(test)
test_typed_composite_predicate :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b)
	from(&b, Users)
	where_(&b, or_(eq(Users.age, 18), and_(gt(Users.age, 65), is_not_null(Users.name))))

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT * FROM users WHERE (users.age = ? OR (users.age > ? AND users.name IS NOT NULL))",
	)
	testing.expect_value(t, len(args), 2)
}

@(test)
test_typed_order_desc :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b)
	from(&b, Users)
	order_by(&b, desc(Users.age), asc(Users.name))

	q, _ := to_query(&b)
	testing.expect_value(t, q, "SELECT * FROM users ORDER BY users.age DESC, users.name")
}

@(test)
test_typed_insert :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	insert_into(&b, Users, bind(Users.name, "alice"), bind(Users.age, 30))

	q, args := to_query(&b)
	testing.expect_value(t, q, "INSERT INTO users (name, age) VALUES (?, ?)")
	testing.expect_value(t, len(args), 2)
}

@(test)
test_typed_with :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	// CTE descriptor: same shape as a table descriptor, qualified by the CTE
	// name, with the columns the body's SELECT exposes.
	Adults := struct {
		_info: Table_Info,
		id:    Column(i64),
		name:  Column(string),
	} {
		_info = {name = "adults"},
		id = {base = {table = "adults", name = "id", type_id = i64}},
		name = {base = {table = "adults", name = "name", type_id = string}},
	}

	sub: Builder
	init(&sub)
	defer destroy(&sub)
	select(&sub, Users.id, Users.name)
	from(&sub, Users)
	where_(&sub, ge(Users.age, 18))

	with(&b, Adults, &sub)
	select(&b, Adults.id, Adults.name)
	from(&b, Adults)

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"WITH adults AS (SELECT users.id, users.name FROM users WHERE users.age >= ?) SELECT adults.id, adults.name FROM adults",
	)
	testing.expect_value(t, len(args), 1)
}

@(test)
test_typed_with_recursive :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	Cnt := struct {
		_info: Table_Info,
		n:     Column(i64),
	} {
		_info = {name = "cnt"},
		n = {base = {table = "cnt", name = "n", type_id = i64}},
	}

	sub: Builder
	init(&sub)
	defer destroy(&sub)
	raw_select(&sub, "1")

	with(&b, Cnt, &sub, recursive = true)
	select(&b, Cnt.n)
	from(&b, Cnt)

	q, _ := to_query(&b)
	testing.expect_value(t, q, "WITH RECURSIVE cnt AS (SELECT 1) SELECT cnt.n FROM cnt")
}

@(test)
test_typed_update :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	update(&b, Users)
	set(&b, Users.name, "bob")
	set(&b, Users.age, 25)
	where_(&b, eq(Users.id, i64(1)))

	q, args := to_query(&b)
	testing.expect_value(t, q, "UPDATE users SET name = ?, age = ? WHERE users.id = ?")
	testing.expect_value(t, len(args), 3)
}

@(test)
test_typed_delete :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	delete_from(&b, Users)
	where_(&b, lt(Users.age, 18))

	q, args := to_query(&b)
	testing.expect_value(t, q, "DELETE FROM users WHERE users.age < ?")
	testing.expect_value(t, len(args), 1)
}

@(test)
test_typed_join :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b, Users.id, Posts.title)
	from(&b, Users)
	join(&b, Posts, col_eq(Posts.user_id, Users.id))
	where_(&b, ge(Users.age, 18))

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT users.id, posts.title FROM users JOIN posts ON posts.user_id = users.id WHERE users.age >= ?",
	)
	testing.expect_value(t, len(args), 1)
}

@(test)
test_typed_left_join_composite_on :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	select(&b)
	from(&b, Users)
	join(
		&b,
		Posts,
		and_(col_eq(Posts.user_id, Users.id), col_ne(Posts.id, Users.id)),
		kind = .Left,
	)

	q, _ := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT * FROM users LEFT JOIN posts ON (posts.user_id = users.id AND posts.id != users.id)",
	)
}

// --- Raw layer ---

@(test)
test_raw_select_with_where_and_order :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	raw_select(&b, "id", "name")
	raw_from(&b, "users")
	raw_where(&b, "age >= ?", i64(18))
	raw_where(&b, "name != ?", "bot")
	raw_order_by(&b, "name")
	limit(&b, 10)

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT id, name FROM users WHERE age >= ? AND name != ? ORDER BY name LIMIT 10",
	)
	testing.expect_value(t, len(args), 2)
}

@(test)
test_raw_multi_join :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	raw_select(&b, "u.id", "p.title")
	raw_from(&b, "users u")
	raw_join(&b, "posts p", "p.user_id = u.id")
	raw_join(&b, "comments c", "c.post_id = p.id")
	raw_where(&b, "u.id = ?", i64(1))

	q, args := to_query(&b)
	testing.expect_value(
		t,
		q,
		"SELECT u.id, p.title FROM users u JOIN posts p ON p.user_id = u.id JOIN comments c ON c.post_id = p.id WHERE u.id = ?",
	)
	testing.expect_value(t, len(args), 1)
}

@(test)
test_reset_clears_all_counts :: proc(t: ^testing.T) {
	b: Builder
	init(&b)
	defer destroy(&b)

	// First query — exercise all counters.
	select(&b)
	from(&b, Users)
	raw_join(&b, "b", "b.id = a.id")
	where_(&b, eq(Users.id, i64(1)))

	reset(&b)

	// Second query should start clean — no leftover " AND " on the first
	// where, no leftover join_count quirks.
	select(&b)
	from(&b, Users)
	where_(&b, eq(Users.age, 2))

	q, _ := to_query(&b)
	testing.expect_value(t, q, "SELECT * FROM users WHERE users.age = ?")
}

@(test)
test_ident_validation :: proc(t: ^testing.T) {
	testing.expect(t, ident("name"), "name should pass")
	testing.expect(t, ident("user_id"), "user_id should pass")
	testing.expect(t, ident("users.id"), "users.id should pass")
	testing.expect(t, ident("u1"), "u1 should pass")
	testing.expect(t, !ident(""), "empty should fail")
	testing.expect(t, !ident("1abc"), "digit-prefixed should fail")
	testing.expect(t, !ident("a;DROP"), "semicolons forbidden")
	testing.expect(t, !ident("a.b.c"), "two dots forbidden")
	testing.expect(t, !ident(".name"), "leading dot forbidden")
	testing.expect(t, !ident("name."), "trailing dot forbidden")
	testing.expect(t, !ident("name space"), "spaces forbidden")
}

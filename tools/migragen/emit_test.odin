package migragen

import "core:strings"
import "core:testing"

import migrate "database:migrate"

@(test)
test_emit_basic :: proc(t: ^testing.T) {
	migs := []migrate.Migration {
		{version = 20260101000000, name = "create_users", up = "CREATE TABLE users (id INTEGER);", down = "DROP TABLE users;"},
	}
	src := emit("myapp", "MIGRATIONS", migs)
	defer delete(src)

	testing.expect(t, strings.contains(src, "package myapp"), "package decl")
	testing.expect(t, strings.contains(src, "import migrate \"database:migrate\""), "migrate import")
	testing.expect(t, strings.contains(src, "MIGRATIONS := []migrate.Migration{"), "slice decl")
	testing.expect(t, strings.contains(src, "version = 20260101000000"), "version literal")
	testing.expect(t, strings.contains(src, "name    = \"create_users\""), "name literal")
	testing.expect(t, strings.contains(src, "DO NOT EDIT"), "header")
}

@(test)
test_emit_escapes_special_chars :: proc(t: ^testing.T) {
	// SQL with a newline, a tab, a double-quote and a backslash must produce a
	// valid Odin string literal.
	migs := []migrate.Migration {
		{version = 1, name = "q", up = "SELECT '\t' AS \"x\\y\";\nSELECT 1;", down = ""},
	}
	src := emit("p", "M", migs)
	defer delete(src)

	testing.expect(t, strings.contains(src, "\\n"), "newline escaped")
	testing.expect(t, strings.contains(src, "\\t"), "tab escaped")
	testing.expect(t, strings.contains(src, "\\\"x\\\\y\\\""), "quote and backslash escaped")
	// Empty down stays an empty literal.
	testing.expect(t, strings.contains(src, "down    = \"\""), "empty down literal")
}

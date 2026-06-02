package migranew

import "core:os"
import "core:testing"
import "core:time"

import migrate "database:migrate"

@(test)
test_sanitize_name :: proc(t: ^testing.T) {
	testing.expect_value(t, sanitize_name("Create Users Table"), "create_users_table")
	testing.expect_value(t, sanitize_name("add-index!!"), "add_index")
	testing.expect_value(t, sanitize_name("  spaced out  "), "spaced_out")
	testing.expect_value(t, sanitize_name("MixOf__things 2"), "mixof_things_2")
	testing.expect_value(t, sanitize_name("!!!"), "")
	testing.expect_value(t, sanitize_name(""), "")
}

@(test)
test_version_stamp :: proc(t: ^testing.T) {
	tm, _ := time.datetime_to_time(2026, 1, 2, 3, 4, 5)
	testing.expect_value(t, version_stamp(tm), "20260102030405")
}

// The scaffolded pair must round-trip through the migrate filename convention:
// migrate.from_dir loads exactly one migration with the stamped version and the
// sanitized name. A second scaffold with the same version must refuse to clobber.
@(test)
test_scaffold_roundtrip :: proc(t: ^testing.T) {
	dir := "migranew_test_tmp"
	os.remove_all(dir) // defensive: clear any leftover from a previous failed run
	defer os.remove_all(dir)

	up, down, problem := scaffold(dir, "create_users", "20260102030405", true)
	testing.expect_value(t, problem, "")
	testing.expect(t, os.exists(up), "expected .up.sql to be written")
	testing.expect(t, os.exists(down), "expected .down.sql to be written")

	migs, err := migrate.from_dir(dir)
	defer migrate.destroy_migrations(migs)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(migs), 1)
	if len(migs) == 1 {
		testing.expect_value(t, migs[0].version, i64(20260102030405))
		testing.expect_value(t, migs[0].name, "create_users")
	}

	// A second scaffold at the same version/name must not overwrite.
	_, _, problem2 := scaffold(dir, "create_users", "20260102030405", true)
	testing.expect(t, problem2 != "", "expected a collision problem on the second scaffold")
}

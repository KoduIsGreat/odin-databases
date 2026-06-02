// migranew — scaffold a new, empty migration into a directory: a paired
// `<version>_<name>.up.sql` and `<version>_<name>.down.sql`, where <version> is
// a fresh 14-digit `YYYYMMDDHHMMSS` timestamp. It uses the same filename
// convention as database:migrate's `from_dir`, so the files it writes load back
// through the runner unchanged.
//
// Usage:
//   odin run tools/migranew -- <dir> <name> [-no-down]
//   odb migrate-new <dir> <name> [-no-down]
//
//   <dir>    migrations directory (created if it does not exist)
//   <name>   human-readable label; sanitized to snake_case for the filename
//   -no-down only write the .up.sql half
package migranew

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import migrate "database:migrate"

// Options is the migranew command line, parsed declaratively by core:flags.
Options :: struct {
	dir:     string `args:"pos=0,required" usage:"migrations directory (created if it does not exist)"`,
	name:    string `args:"pos=1,required" usage:"migration name (e.g. 'create users' -> <version>_create_users.{up,down}.sql)"`,
	no_down: bool `args:"name=no-down"     usage:"only write the .up.sql half (skip .down.sql)"`,
}

// run parses args and scaffolds the migration, returning a process exit code.
// `prog` is the program name shown in usage ("migranew" standalone,
// "odb migrate-new" under the unified CLI). Exposed for the `odb` dispatcher.
run :: proc(prog: string, args: []string) -> int {
	opt: Options
	program_args := make([]string, len(args) + 1, context.temp_allocator)
	program_args[0] = prog
	copy(program_args[1:], args)
	flags.parse_or_exit(&opt, program_args) // handles -h / usage / errors

	slug := sanitize_name(opt.name)
	if slug == "" {
		fmt.eprintfln(
			"migranew: migration name %q has no usable characters (use letters, digits, spaces, '-' or '_')",
			opt.name,
		)
		return 2
	}

	version := version_stamp(time.now())
	up_path, down_path, problem := scaffold(opt.dir, slug, version, !opt.no_down)
	if problem != "" {
		fmt.eprintfln("migranew: %s", problem)
		return 1
	}

	fmt.printfln("migranew: wrote %s", up_path)
	if !opt.no_down {
		fmt.printfln("migranew: wrote %s", down_path)
	}
	return 0
}

main :: proc() {
	os.exit(run(os.args[0], os.args[1:]))
}

// version_stamp renders a time as the 14-digit YYYYMMDDHHMMSS ordering key that
// `migrate.from_dir` expects as the <version> portion of a filename.
version_stamp :: proc(t: time.Time) -> string {
	yr, mo, dy := time.date(t)
	hr, mn, sc := time.clock(t)
	return fmt.tprintf("%04d%02d%02d%02d%02d%02d", yr, int(mo), dy, hr, mn, sc)
}

// sanitize_name lowercases `name` and collapses every run of non-alphanumeric
// characters into a single underscore, trimming leading/trailing underscores.
// Returns "" if nothing usable remains. Allocates with `allocator`.
sanitize_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	at_boundary := true // collapse a leading run of separators to nothing
	for i in 0 ..< len(name) {
		c := name[i]
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&b, c + 32)
			at_boundary = false
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_byte(&b, c)
			at_boundary = false
		case:
			if !at_boundary {
				strings.write_byte(&b, '_')
				at_boundary = true
			}
		}
	}
	return strings.trim_right(strings.to_string(b), "_")
}

// scaffold writes the migration pair into `dir` (creating `dir` if needed) and
// returns the file paths plus a problem message ("" on success). It never
// overwrites an existing file. `version` must be the all-digit stamp from
// version_stamp. Paths and messages are allocated with `allocator`.
scaffold :: proc(
	dir, slug, version: string,
	with_down: bool,
	allocator := context.temp_allocator,
) -> (
	up_path, down_path, problem: string,
) {
	if !os.exists(dir) {
		if derr := os.make_directory_all(dir); derr != nil {
			return "", "", fmt.aprintf("create dir %q: %v", dir, derr, allocator = allocator)
		}
	}

	base := fmt.aprintf("%s_%s", version, slug, allocator = allocator)
	up_path, _ = filepath.join(
		{dir, fmt.aprintf("%s%s", base, migrate.UP_SUFFIX, allocator = allocator)},
		allocator,
	)
	if with_down {
		down_path, _ = filepath.join(
			{dir, fmt.aprintf("%s%s", base, migrate.DOWN_SUFFIX, allocator = allocator)},
			allocator,
		)
	}

	// Never clobber existing files.
	if os.exists(up_path) {
		return up_path, down_path, fmt.aprintf("%s already exists", up_path, allocator = allocator)
	}
	if with_down && os.exists(down_path) {
		return up_path, down_path, fmt.aprintf("%s already exists", down_path, allocator = allocator)
	}

	up_body := fmt.aprintf(
		"-- %s%s\n-- Forward migration: write the schema change here.\n",
		base,
		migrate.UP_SUFFIX,
		allocator = allocator,
	)
	if werr := os.write_entire_file(up_path, transmute([]u8)up_body); werr != nil {
		return up_path, down_path, fmt.aprintf("write %s: %v", up_path, werr, allocator = allocator)
	}
	if with_down {
		down_body := fmt.aprintf(
			"-- %s%s\n-- Reverse migration: undo the .up.sql change here.\n",
			base,
			migrate.DOWN_SUFFIX,
			allocator = allocator,
		)
		if werr := os.write_entire_file(down_path, transmute([]u8)down_body); werr != nil {
			return up_path, down_path, fmt.aprintf(
				"write %s: %v",
				down_path,
				werr,
				allocator = allocator,
			)
		}
	}
	return up_path, down_path, ""
}

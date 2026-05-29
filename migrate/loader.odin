package migrate

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// File-name suffixes that mark the forward and reverse halves of a migration.
UP_SUFFIX :: ".up.sql"
DOWN_SUFFIX :: ".down.sql"

// from_dir loads migrations from `dir`, reading every file named
//
//	<version>_<name>.up.sql      (required)
//	<version>_<name>.down.sql    (optional)
//
// where <version> is an all-digit ordering key (by convention a 14-digit
// YYYYMMDDHHMMSS timestamp). Files are paired by version; a .down.sql with no
// matching .up.sql is a .Missing_Up error. The returned slice is sorted by
// version. Non-matching files (and subdirectories) are ignored.
//
// The slice, the SQL bodies, and the names are allocated with `allocator`; free
// them with destroy_migrations.
from_dir :: proc(
	dir: string,
	allocator := context.allocator,
) -> (
	migrations: []Migration,
	err: Error,
) {
	infos, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {
		return nil, Migrate_Error {
			kind = .Read_Failed,
			detail = fmt.aprintf("read dir %q: %v", dir, derr, allocator = allocator),
		}
	}

	// Accumulate the up/down halves per version before assembling Migrations.
	Pending :: struct {
		name:   string,
		up:     string,
		down:   string,
		has_up: bool,
	}
	pend := make(map[i64]Pending, allocator = context.temp_allocator)

	for info in infos {
		if info.type == .Directory {continue}
		fname := info.name

		is_up := strings.has_suffix(fname, UP_SUFFIX)
		is_down := strings.has_suffix(fname, DOWN_SUFFIX)
		if !is_up && !is_down {continue}

		suffix := UP_SUFFIX if is_up else DOWN_SUFFIX
		base := fname[:len(fname) - len(suffix)]

		// Split <version>_<name>; both parts must be non-empty.
		us := strings.index_byte(base, '_')
		if us <= 0 || us == len(base) - 1 {
			return nil, bad_filename(fname, allocator)
		}
		vstr, mname := base[:us], base[us + 1:]
		if !all_digits(vstr) {
			return nil, bad_filename(fname, allocator)
		}
		version, ok := strconv.parse_i64_of_base(vstr, 10)
		if !ok {
			return nil, bad_filename(fname, allocator)
		}

		data, rerr := os.read_entire_file_from_path(info.fullpath, allocator)
		if rerr != nil {
			return nil, Migrate_Error {
				kind = .Read_Failed,
				version = version,
				detail = fmt.aprintf("read %q: %v", fname, rerr, allocator = allocator),
			}
		}

		p := pend[version]
		if is_up {
			p.up = string(data)
			p.name = strings.clone(mname, allocator)
			p.has_up = true
		} else {
			p.down = string(data)
		}
		pend[version] = p
	}

	versions := make([dynamic]i64, 0, len(pend), context.temp_allocator)
	for v in pend {
		append(&versions, v)
	}
	slice.sort(versions[:])

	result := make([dynamic]Migration, 0, len(versions), allocator)
	for v in versions {
		p := pend[v]
		if !p.has_up {
			delete(result)
			return nil, Migrate_Error{kind = .Missing_Up, version = v}
		}
		append(&result, Migration{version = v, name = p.name, up = p.up, down = p.down})
	}
	return result[:], nil
}

// destroy_migrations frees a slice returned by from_dir, including the SQL
// bodies and names it allocated.
destroy_migrations :: proc(migrations: []Migration, allocator := context.allocator) {
	for m in migrations {
		delete(m.name, allocator)
		delete(m.up, allocator)
		delete(m.down, allocator) // delete("") is a no-op
	}
	delete(migrations, allocator)
}

@(private)
bad_filename :: proc(fname: string, allocator: mem.Allocator) -> Migrate_Error {
	return Migrate_Error{kind = .Bad_Filename, detail = strings.clone(fname, allocator)}
}

@(private)
all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	for c in s {
		if c < '0' || c > '9' {return false}
	}
	return true
}

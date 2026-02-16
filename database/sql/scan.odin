package sql

import "base:intrinsics"
import "base:runtime"
import "core:time"

MAX_SCAN_COLS :: 64

// scan advances to the next row and maps column values into struct
// fields by matching column names to field names (exact match).
//
// Returns false when no more rows remain.
// Fields with no matching column are left unchanged.
// Columns with no matching field are silently skipped.
//
// Values written to string/[]byte fields are BORROWED — valid only
// until the next scan() call or close_rows().
//
// Usage:
//   user: User
//   for sql.scan(&rows, &user) {
//       fmt.println(user.name)
//   }
scan :: proc(rows: ^Rows, dest: ^$T) -> bool where intrinsics.type_is_struct(T) {
	if rows.closed {return false}

	cols := columns(rows)
	if cols == nil {return false}

	ncols := len(cols)
	assert(ncols <= MAX_SCAN_COLS)

	values: [MAX_SCAN_COLS]Value
	if !next(rows, values[:ncols]) {return false}

	info := runtime.type_info_base(type_info_of(T))
	si := info.variant.(runtime.Type_Info_Struct)

	for ci in 0 ..< ncols {
		col_name := cols[ci].name
		for fi in 0 ..< si.field_count {
			if si.names[fi] == col_name {
				set_field(dest, si.offsets[fi], si.types[fi].id, values[ci])
				break
			}
		}
	}

	return true
}

@(private)
set_field :: proc(base: rawptr, offset: uintptr, tid: typeid, val: Value) {
	ptr := rawptr(uintptr(base) + offset)

	#partial switch v in val {
	case i64:
		switch tid {
		case i64:
			(^i64)(ptr)^ = v
		case int:
			(^int)(ptr)^ = int(v)
		case i32:
			(^i32)(ptr)^ = i32(v)
		case i16:
			(^i16)(ptr)^ = i16(v)
		case u64:
			(^u64)(ptr)^ = u64(v)
		case uint:
			(^uint)(ptr)^ = uint(v)
		case u32:
			(^u32)(ptr)^ = u32(v)
		case u16:
			(^u16)(ptr)^ = u16(v)
		case bool:
			(^bool)(ptr)^ = v != 0
		}
	case f64:
		switch tid {
		case f64:
			(^f64)(ptr)^ = v
		case f32:
			(^f32)(ptr)^ = f32(v)
		}
	case string:
		if tid == string {
			(^string)(ptr)^ = v
		}
	case []byte:
		if tid == []byte {
			(^[]byte)(ptr)^ = v
		}
	case bool:
		if tid == bool {
			(^bool)(ptr)^ = v
		}
	case time.Time:
		if tid == time.Time {
			(^time.Time)(ptr)^ = v
		}
	case Null:
	// Leave field unchanged
	}
}

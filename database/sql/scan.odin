package sql

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"
import "core:time"

// scan_struct maps the current row's column values into struct fields
// by matching column names to field names (exact match).
//
// Fields with no matching column are left unchanged.
// Columns with no matching field are silently skipped.
//
// String and []byte values are cloned using context.allocator,
// so they remain valid after close_rows(). The caller owns the memory.
//
// Usage:
//   for sql.next(&rows) {
//       user: User
//       sql.scan(&rows, &user)
//   }
scan_struct :: proc(rows: ^Rows, dest: ^$T) -> Error where intrinsics.type_is_struct(T) {
	if !rows.has_row {
		return Scan_Error.No_Row
	}

	info := runtime.type_info_base(type_info_of(T))
	si := info.variant.(runtime.Type_Info_Struct)

	for ci in 0 ..< rows.col_count {
		col_name := rows._cols[ci].name
		for fi in 0 ..< si.field_count {
			if si.names[fi] == col_name {
				set_field(dest, si.offsets[fi], si.types[fi].id, rows._values[ci], rows._detached)
				break
			}
		}
	}

	return nil
}

// scan_values writes the current row's column values positionally
// into the provided pointer arguments.
//
// Each element must be a pointer (^int, ^string, ^bool, etc.).
// Column 0 → first element, column 1 → second element, and so on.
// The number of destinations must match the number of columns.
//
// String and []byte values are cloned using context.allocator,
// so they remain valid after close_rows(). The caller owns the memory.
//
// Usage:
//   for sql.next(&rows) {
//       name: string
//       age:  int
//       sql.scan(&rows, &name, &age)
//   }
scan_values :: proc(rows: ^Rows, dests: ..any) -> Error {
	return scan_values_impl(rows, dests)
}

@(private)
scan_values_impl :: proc(rows: ^Rows, dests: []any) -> Error {
	if !rows.has_row {
		return Scan_Error.No_Row
	}

	if len(dests) != rows.col_count {
		return Scan_Error.Column_Count_Mismatch
	}

	for i in 0 ..< len(dests) {
		d := dests[i]
		ptr_info := runtime.type_info_base(type_info_of(d.id))
		p, ok := ptr_info.variant.(runtime.Type_Info_Pointer)
		if !ok {
			return Scan_Error.Dest_Not_Pointer
		}
		dest_ptr := (^rawptr)(d.data)^
		set_field(dest_ptr, 0, p.elem.id, rows._values[i], rows._detached)
	}

	return nil
}

// row_scan_struct scans from a Row (returned by query_row).
// If the Row carries an error (query failure or no rows), it is
// returned immediately without scanning.
row_scan_struct :: proc(row: ^Row, dest: ^$T) -> Error where intrinsics.type_is_struct(T) {
	if row.err != nil {return row.err}
	return scan_struct(&row.rows, dest)
}

// row_scan_values scans from a Row (returned by query_row).
// If the Row carries an error, it is returned immediately.
row_scan_values :: proc(row: ^Row, dests: ..any) -> Error {
	if row.err != nil {return row.err}
	return scan_values_impl(&row.rows, dests)
}

scan :: proc {
	row_scan_struct,
	row_scan_values,
	scan_struct,
	scan_values,
}

@(private)
set_field :: proc(base: rawptr, offset: uintptr, tid: typeid, val: Value, owned: bool) {
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
			(^string)(ptr)^ = v if owned else strings.clone(v)
		}
	case []byte:
		if tid == []byte {
			if owned {
				(^[]byte)(ptr)^ = v
			} else {
				cloned := make([]byte, len(v))
				copy(cloned, v)
				(^[]byte)(ptr)^ = cloned
			}
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

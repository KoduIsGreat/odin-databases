package sql

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
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
// For detached rows (from query_row), values are already owned and
// are moved directly without cloning.
//
// Usage:
//   for sql.next(&rows) {
//       user: User
//       sql.scan(&rows, &user)
//   }
scan_struct :: proc(rows: ^Rows, dest: ^$T) -> Error where intrinsics.type_is_struct(T) {
	if !rows.has_row {
		return Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""}
	}

	info := runtime.type_info_base(type_info_of(T))
	si := info.variant.(runtime.Type_Info_Struct)

	for ci in 0 ..< rows.col_count {
		col_name := rows._cols[ci].name
		for fi in 0 ..< si.field_count {
			if si.names[fi] == col_name {
				if vtype := set_field(
					dest,
					si.offsets[fi],
					si.types[fi].id,
					rows._values[ci],
					rows._detached,
				); vtype != nil {
					return Scan_Error {
						kind = .Column_Type_Mismatch,
						col_idx = ci,
						col_name = col_name,
						dest_type = type_of(dest^),
						value_type = vtype,
					}
				}
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
// For detached rows (from query_row), values are already owned and
// are moved directly without cloning.
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
		return Scan_Error{kind = .No_Row, col_idx = -1, col_name = ""}
	}

	if len(dests) != rows.col_count {
		return Scan_Error{kind = .Column_Count_Mismatch, col_idx = -1, col_name = ""}
	}

	for i in 0 ..< len(dests) {
		d := dests[i]
		ptr_info := runtime.type_info_base(type_info_of(d.id))
		p, ok := ptr_info.variant.(runtime.Type_Info_Pointer)
		if !ok {
			return Scan_Error {
				kind = .Dest_Not_Pointer,
				col_idx = i,
				col_name = rows._cols[i].name,
				dest_type = d.id,
				value_type = rows._cols[i].type_id,
			}
		}
		dest_ptr := (^rawptr)(d.data)^
		if vtype := set_field(dest_ptr, 0, p.elem.id, rows._values[i], rows._detached);
		   vtype != nil {
			return Scan_Error {
				kind = .Column_Type_Mismatch,
				col_idx = i,
				col_name = rows._cols[i].name,
				dest_type = d.id,
				value_type = vtype,
			}

		}
	}

	return nil
}

// row_scan_struct scans from a Row (returned by query_row).
// The Row's underlying connection is already released, so this
// only reads from buffered values. If the Row carries an error
// (query failure or no rows), it is returned immediately.
row_scan_struct :: proc(row: ^Row, dest: ^$T) -> Error where intrinsics.type_is_struct(T) {
	if row.err != nil {return row.err}
	return scan_struct(&row.rows, dest)
}

// row_scan_values scans from a Row (returned by query_row).
// The Row's underlying connection is already released, so this
// only reads from buffered values. If the Row carries an error,
// it is returned immediately.
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
set_field :: proc(base: rawptr, offset: uintptr, tid: typeid, val: Value, owned: bool) -> typeid {
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
		case:
			return i64
		}
	case f64:
		switch tid {
		case f64:
			(^f64)(ptr)^ = v
		case f32:
			(^f32)(ptr)^ = f32(v)
		case:
			return f64
		}
	case string:
		if tid != string {return string}
		(^string)(ptr)^ = v if owned else strings.clone(v)
	case []byte:
		if tid != []byte {return []byte}
		if owned {
			(^[]byte)(ptr)^ = v
		} else {
			cloned := make([]byte, len(v))
			copy(cloned, v)
			(^[]byte)(ptr)^ = cloned
		}
	case bool:
		if tid != bool {return bool}
		(^bool)(ptr)^ = v
	case time.Time:
		if tid != time.Time {return time.Time}
		(^time.Time)(ptr)^ = v
	case Null:
	// Leave field unchanged
	}
	return nil
}

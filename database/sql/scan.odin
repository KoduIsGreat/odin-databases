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
				if vtype, ok := set_field(
					dest,
					si.offsets[fi],
					si.types[fi].id,
					rows._values[ci],
					rows._detached,
				); !ok {
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
		if vtype, ok := set_field(dest_ptr, 0, p.elem.id, rows._values[i], rows._detached);
		   !ok {
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

// set_field writes a column value into the field at base+offset, coercing
// where possible (e.g. i64→int, i64→bool). On mismatch it returns the
// source value's typeid and ok=false so callers can build a diagnostic.
// On success (or Null, which leaves the field untouched) it returns (_, true).
@(private)
set_field :: proc(
	base: rawptr,
	offset: uintptr,
	tid: typeid,
	val: Value,
	owned: bool,
) -> (
	value_type: typeid,
	ok: bool,
) {
	ptr := rawptr(uintptr(base) + offset)

	// Nil-able single-variant union (Maybe(T)): set the inner value at the
	// union's data (offset 0) and write its tag. A NULL leaves the field at
	// its zero value, which is None.
	if inner, tag_offset, tag_size, is_maybe := maybe_union(tid); is_maybe {
		if _, is_null := val.(Null); is_null {
			return nil, true
		}
		if vtype, set_ok := set_field(ptr, 0, inner, val, owned); !set_ok {
			return vtype, false
		}
		write_union_tag(ptr, tag_offset, tag_size, 1)
		return nil, true
	}

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
			return i64, false
		}
	case f64:
		switch tid {
		case f64:
			(^f64)(ptr)^ = v
		case f32:
			(^f32)(ptr)^ = f32(v)
		case:
			return f64, false
		}
	case string:
		if tid != string {return string, false}
		(^string)(ptr)^ = v if owned else strings.clone(v)
	case []byte:
		if tid != []byte {return []byte, false}
		if owned {
			(^[]byte)(ptr)^ = v
		} else {
			cloned := make([]byte, len(v))
			copy(cloned, v)
			(^[]byte)(ptr)^ = cloned
		}
	case bool:
		if tid != bool {return bool, false}
		(^bool)(ptr)^ = v
	case time.Time:
		if tid != time.Time {return time.Time, false}
		(^time.Time)(ptr)^ = v
	case Null:
	// Leave field unchanged
	}
	return nil, true
}

// maybe_union reports whether tid is a nil-able single-variant union (e.g.
// Maybe(T)), returning the inner variant's typeid and the union's tag layout.
// Used by set_field to scan a column value into an optional struct field.
@(private)
maybe_union :: proc(
	tid: typeid,
) -> (
	inner: typeid,
	tag_offset: uintptr,
	tag_size: int,
	ok: bool,
) {
	ti := runtime.type_info_base(type_info_of(tid))
	u, is_union := ti.variant.(runtime.Type_Info_Union)
	if !is_union {return}
	if len(u.variants) != 1 || u.no_nil {return}
	return u.variants[0].id, u.tag_offset, u.tag_type.size, true
}

// write_union_tag writes a union's active-variant tag (1-based for nil-able
// unions; 0 means nil/None) at ptr + tag_offset, sized per the tag type.
@(private)
write_union_tag :: proc(ptr: rawptr, tag_offset: uintptr, tag_size: int, tag: u64) {
	tagptr := rawptr(uintptr(ptr) + tag_offset)
	switch tag_size {
	case 1:
		(^u8)(tagptr)^ = u8(tag)
	case 2:
		(^u16)(tagptr)^ = u16(tag)
	case 4:
		(^u32)(tagptr)^ = u32(tag)
	case 8:
		(^u64)(tagptr)^ = u64(tag)
	}
}

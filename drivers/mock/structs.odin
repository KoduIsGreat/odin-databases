package sqlmock

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:time"

import drv "database:sql/driver"

// returns_structs configures a Query/Stmt_Query expectation from typed row
// structs: each field name becomes a column name and each field value a column
// value. It is the type-safe, schema-driven counterpart to returns_rows — pass
// your generated row structs (or any struct) instead of hand-written
// column-name strings and a []Value matrix:
//
//     mock.returns_structs(mock.expect_query(m, "SELECT"), []User{
//         {id = 1, name = "Alice", age = 30},
//         {id = 3, name = "Carol", age = 41},
//     })
//
// Field types map to driver Values the same way scanning maps them back: int
// family → i64, f32 → f64, string / []byte / bool / time.Time as-is, and a
// Maybe(T) field yields the wrapped value when present or SQL NULL when None.
//
// All payloads are deep-copied into the mock's allocator, so the structs may
// be stack-local or dynamically built and need not outlive the query.
returns_structs :: proc(e: ^Expectation, rows: []$T) -> ^Expectation where intrinsics.type_is_struct(T) {
	ti := runtime.type_info_base(type_info_of(T))
	si := ti.variant.(runtime.Type_Info_Struct)

	cols := make([]string, si.field_count, context.temp_allocator)
	for i in 0 ..< si.field_count {
		cols[i] = si.names[i]
	}

	vrows := make([][]drv.Value, len(rows), context.temp_allocator)
	for i in 0 ..< len(rows) {
		base := uintptr(&rows[i])
		vals := make([]drv.Value, si.field_count, context.temp_allocator)
		for fi in 0 ..< si.field_count {
			vals[fi] = struct_field_value(any{rawptr(base + si.offsets[fi]), si.types[fi].id})
		}
		vrows[i] = vals
	}

	return returns_rows(e, cols, vrows)
}

// with_struct_args asserts that the next matching call's bound arguments equal
// the struct's field values, in field order. It is the type-safe counterpart
// to with_args: instead of writing an `Args_Predicate` and hand-wrapping
// Values, you pass a struct of expected values.
//
//     mock.with_struct_args(
//         mock.expect_exec(m, "UPDATE"),
//         struct{name: string, id: i64}{"frank", 7},
//     )
//
// Field *names* are ignored — only the order and values matter (query args are
// positional). Field types convert to Values like returns_structs does, and
// payloads are deep-copied into the mock's allocator.
with_struct_args :: proc(e: ^Expectation, args: $T) -> ^Expectation where intrinsics.type_is_struct(T) {
	a := args
	ti := runtime.type_info_base(type_info_of(T))
	si := ti.variant.(runtime.Type_Info_Struct)

	vals := make([]drv.Value, si.field_count, e.mock.allocator)
	base := uintptr(&a)
	for fi in 0 ..< si.field_count {
		v := struct_field_value(any{rawptr(base + si.offsets[fi]), si.types[fi].id})
		vals[fi] = clone_value(v, e.mock.allocator) // own the data; don't alias `args`
	}
	e.expected_args = vals
	e.has_expected_args = true
	return e
}

// args_equal reports whether two positional Value slices match element-wise.
@(private)
args_equal :: proc(expected, actual: []drv.Value) -> bool {
	if len(expected) != len(actual) {
		return false
	}
	for i in 0 ..< len(expected) {
		if !values_equal(expected[i], actual[i]) {
			return false
		}
	}
	return true
}

// values_equal compares two driver Values by variant and contents.
@(private)
values_equal :: proc(a, b: drv.Value) -> bool {
	switch av in a {
	case bool:
		v, ok := b.(bool); return ok && v == av
	case i64:
		v, ok := b.(i64); return ok && v == av
	case i128:
		v, ok := b.(i128); return ok && v == av
	case u128:
		v, ok := b.(u128); return ok && v == av
	case f64:
		v, ok := b.(f64); return ok && v == av
	case string:
		v, ok := b.(string); return ok && v == av
	case []byte:
		v, ok := b.([]byte); return ok && slice.equal(v, av)
	case time.Time:
		v, ok := b.(time.Time); return ok && v == av
	case drv.Custom_Value:
		// Opaque driver cell; the mock never produces these, so compare by
		// identity of the convert proc and inline storage.
		v, ok := b.(drv.Custom_Value); return ok && v == av
	case drv.Null:
		_, ok := b.(drv.Null); return ok
	case:
		return b == nil // both Values nil (no variant)
	}
}

// struct_field_value converts a struct field (given as an `any`) into the
// driver `Value` the field would round-trip to. Mirrors the scan layer's
// coercions and unwraps a Maybe(T) field to its value or NULL.
@(private)
struct_field_value :: proc(a: any) -> drv.Value {
	ti := runtime.type_info_base(type_info_of(a.id))

	// A nil-able single-variant union (Maybe(T)) → its value, or NULL if None.
	if u, is_union := ti.variant.(runtime.Type_Info_Union); is_union {
		if len(u.variants) == 1 && !u.no_nil {
			if inner := reflect.get_union_variant(a); inner != nil {
				return struct_field_value(inner)
			}
			return drv.Null{type_hint = u.variants[0].id}
		}
	}

	switch a.id {
	case bool:
		return (^bool)(a.data)^
	case i64:
		return (^i64)(a.data)^
	case int:
		return i64((^int)(a.data)^)
	case i32:
		return i64((^i32)(a.data)^)
	case i16:
		return i64((^i16)(a.data)^)
	case i8:
		return i64((^i8)(a.data)^)
	case u64:
		return i64((^u64)(a.data)^)
	case uint:
		return i64((^uint)(a.data)^)
	case u32:
		return i64((^u32)(a.data)^)
	case u16:
		return i64((^u16)(a.data)^)
	case u8:
		return i64((^u8)(a.data)^)
	case f64:
		return (^f64)(a.data)^
	case f32:
		return f64((^f32)(a.data)^)
	case string:
		return (^string)(a.data)^
	case []byte:
		return (^[]byte)(a.data)^
	case time.Time:
		return (^time.Time)(a.data)^
	}
	fmt.panicf("sqlmock: returns_structs: unsupported field type %v", a.id)
}

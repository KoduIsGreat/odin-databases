package sql

import "base:runtime"

// with_query attaches diagnostic context — the SQL text and the application
// call site (captured via #caller_location at the public API boundary) — to an
// error on its way back to the caller. Pool_Error is a bare enum and passes
// through untouched; a pool failure is not a property of the query anyway.
//
// The query string is borrowed, not cloned — see Error_Ctx in
// `database:driver` for the lifetime contract.
@(private)
with_query :: proc(err: Error, query: string, loc: runtime.Source_Code_Location) -> Error {
	e := err
	#partial switch &v in e {
	case Driver_Error:
		v.query = query
		v.loc = loc
	case Arg_Error:
		v.query = query
		v.loc = loc
	case Scan_Error:
		v.query = query
		v.loc = loc
	}
	return e
}

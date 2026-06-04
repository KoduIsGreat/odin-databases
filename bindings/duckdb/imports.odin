// Cross-platform foreign import block, appended into the generated package by
// odin-c-bindgen (configured via bindgen.sjson `imports_file`).
//
// Prebuilt DuckDB libraries live under ../lib/<os>_<arch>/. They are NOT checked
// in (each is ~50MB); fetch one for your host with ../fetch_libs.sh (or
// `just duckdb-lib`). We link the shared library, so the loader must be able to
// find it at runtime — the `just` duckdb recipes set LD_LIBRARY_PATH /
// DYLD_LIBRARY_PATH to the lib dir for you.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/linux_amd64/libduckdb.so", "system:c"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/linux_arm64/libduckdb.so", "system:c"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/darwin_arm64/libduckdb.dylib", "system:c"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/darwin_amd64/libduckdb.dylib", "system:c"}
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib "../lib/windows_amd64/duckdb.lib"
} else {
	#panic(
		"odin-databases/duckdb: no prebuilt DuckDB library configured for this OS/ARCH. " +
		"Fetch one into bindings/duckdb/lib/<os>_<arch>/ and add a matching branch here.",
	)
}

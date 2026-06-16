// Cross-platform foreign import block, appended into the generated package by
// odin-c-bindgen (configured via bindgen.sjson `imports_file`).
//
// DuckDB is linked STATICALLY on macOS and Linux from the pre-compiled
// archives in ../lib/<os>_<arch>/ — libduckdb_static.a plus the third-party
// and bundled-extension archives, exactly the set go-duckdb links. They are
// NOT checked in (~100MB per platform); fetch them for your host with
// ../fetch_libs.sh (or `just duckdb-lib`), which pulls them from
// github.com/duckdb/duckdb-go-bindings at the pinned tag. Static linking
// makes binaries self-contained — no LD_LIBRARY_PATH / DYLD_LIBRARY_PATH at
// run time, at the cost of ~50MB of binary size.
//
// DuckDB is C++, so the C++ runtime must be linked alongside the archives
// (`system:c++` on macOS, `system:stdc++` + `system:m` + `system:dl` on
// Linux) — the static archives do not carry it. The archive order mirrors
// duckdb-go-bindings' LDFLAGS.
//
// Windows still links the official shared duckdb.lib/duckdb.dll: the static
// archives upstream are MinGW-format, which the MSVC linker Odin uses cannot
// consume. Fetch libduckdb-windows-amd64.zip from a DuckDB release into
// ../lib/windows_amd64/ manually, and keep duckdb.dll next to your binary.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {
		"../lib/linux_amd64/libduckdb_static.a",
		"../lib/linux_amd64/libduckdb_generated_extension_loader.a",
		"../lib/linux_amd64/libautocomplete_extension.a",
		"../lib/linux_amd64/libcore_functions_extension.a",
		"../lib/linux_amd64/libicu_extension.a",
		"../lib/linux_amd64/libjson_extension.a",
		"../lib/linux_amd64/libparquet_extension.a",
		"../lib/linux_amd64/libtpcds_extension.a",
		"../lib/linux_amd64/libtpch_extension.a",
		"../lib/linux_amd64/libduckdb_fastpforlib.a",
		"../lib/linux_amd64/libduckdb_fmt.a",
		"../lib/linux_amd64/libduckdb_fsst.a",
		"../lib/linux_amd64/libduckdb_hyperloglog.a",
		"../lib/linux_amd64/libduckdb_mbedtls.a",
		"../lib/linux_amd64/libduckdb_miniz.a",
		"../lib/linux_amd64/libduckdb_pg_query.a",
		"../lib/linux_amd64/libduckdb_re2.a",
		"../lib/linux_amd64/libduckdb_skiplistlib.a",
		"../lib/linux_amd64/libduckdb_utf8proc.a",
		"../lib/linux_amd64/libduckdb_yyjson.a",
		"../lib/linux_amd64/libduckdb_zstd.a",
		"system:c",
		"system:stdc++",
		"system:m",
		"system:dl",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib {
		"../lib/linux_arm64/libduckdb_static.a",
		"../lib/linux_arm64/libduckdb_generated_extension_loader.a",
		"../lib/linux_arm64/libautocomplete_extension.a",
		"../lib/linux_arm64/libcore_functions_extension.a",
		"../lib/linux_arm64/libicu_extension.a",
		"../lib/linux_arm64/libjson_extension.a",
		"../lib/linux_arm64/libparquet_extension.a",
		"../lib/linux_arm64/libtpcds_extension.a",
		"../lib/linux_arm64/libtpch_extension.a",
		"../lib/linux_arm64/libduckdb_fastpforlib.a",
		"../lib/linux_arm64/libduckdb_fmt.a",
		"../lib/linux_arm64/libduckdb_fsst.a",
		"../lib/linux_arm64/libduckdb_hyperloglog.a",
		"../lib/linux_arm64/libduckdb_mbedtls.a",
		"../lib/linux_arm64/libduckdb_miniz.a",
		"../lib/linux_arm64/libduckdb_pg_query.a",
		"../lib/linux_arm64/libduckdb_re2.a",
		"../lib/linux_arm64/libduckdb_skiplistlib.a",
		"../lib/linux_arm64/libduckdb_utf8proc.a",
		"../lib/linux_arm64/libduckdb_yyjson.a",
		"../lib/linux_arm64/libduckdb_zstd.a",
		"system:c",
		"system:stdc++",
		"system:m",
		"system:dl",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {
		"../lib/darwin_arm64/libduckdb_static.a",
		"../lib/darwin_arm64/libduckdb_generated_extension_loader.a",
		"../lib/darwin_arm64/libautocomplete_extension.a",
		"../lib/darwin_arm64/libcore_functions_extension.a",
		"../lib/darwin_arm64/libicu_extension.a",
		"../lib/darwin_arm64/libjson_extension.a",
		"../lib/darwin_arm64/libparquet_extension.a",
		"../lib/darwin_arm64/libtpcds_extension.a",
		"../lib/darwin_arm64/libtpch_extension.a",
		"../lib/darwin_arm64/libduckdb_fastpforlib.a",
		"../lib/darwin_arm64/libduckdb_fmt.a",
		"../lib/darwin_arm64/libduckdb_fsst.a",
		"../lib/darwin_arm64/libduckdb_hyperloglog.a",
		"../lib/darwin_arm64/libduckdb_mbedtls.a",
		"../lib/darwin_arm64/libduckdb_miniz.a",
		"../lib/darwin_arm64/libduckdb_pg_query.a",
		"../lib/darwin_arm64/libduckdb_re2.a",
		"../lib/darwin_arm64/libduckdb_skiplistlib.a",
		"../lib/darwin_arm64/libduckdb_utf8proc.a",
		"../lib/darwin_arm64/libduckdb_yyjson.a",
		"../lib/darwin_arm64/libduckdb_zstd.a",
		"system:c",
		"system:c++",
	}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib {
		"../lib/darwin_amd64/libduckdb_static.a",
		"../lib/darwin_amd64/libduckdb_generated_extension_loader.a",
		"../lib/darwin_amd64/libautocomplete_extension.a",
		"../lib/darwin_amd64/libcore_functions_extension.a",
		"../lib/darwin_amd64/libicu_extension.a",
		"../lib/darwin_amd64/libjson_extension.a",
		"../lib/darwin_amd64/libparquet_extension.a",
		"../lib/darwin_amd64/libtpcds_extension.a",
		"../lib/darwin_amd64/libtpch_extension.a",
		"../lib/darwin_amd64/libduckdb_fastpforlib.a",
		"../lib/darwin_amd64/libduckdb_fmt.a",
		"../lib/darwin_amd64/libduckdb_fsst.a",
		"../lib/darwin_amd64/libduckdb_hyperloglog.a",
		"../lib/darwin_amd64/libduckdb_mbedtls.a",
		"../lib/darwin_amd64/libduckdb_miniz.a",
		"../lib/darwin_amd64/libduckdb_pg_query.a",
		"../lib/darwin_amd64/libduckdb_re2.a",
		"../lib/darwin_amd64/libduckdb_skiplistlib.a",
		"../lib/darwin_amd64/libduckdb_utf8proc.a",
		"../lib/darwin_amd64/libduckdb_yyjson.a",
		"../lib/darwin_amd64/libduckdb_zstd.a",
		"system:c",
		"system:c++",
	}
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib "../lib/windows_amd64/duckdb.lib"
} else {
	#panic(
		"odin-databases/duckdb: no prebuilt DuckDB library configured for this OS/ARCH. " +
		"Fetch one into bindings/duckdb/lib/<os>_<arch>/ and add a matching branch here.",
	)
}

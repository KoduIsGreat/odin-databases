// Pre-built static libs live under ../lib/<os>_<arch>/.
// Build them with ../build_libs.sh (Unix) or ../build_libs.bat (Windo

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/darwin_arm64/libsqlite3.a", "system:c"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/darwin_amd64/libsqlite3.a", "system:c"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import lib {"../lib/linux_amd64/libsqlite3.a", "system:c", "system:m", "system:dl"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib {"../lib/linux_arm64/libsqlite3.a", "system:c", "system:m", "system:dl", "system:pthread"}
} else when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import lib "../lib/windows_amd64/sqlite3.lib"
} else {
	#panic(
		"odin-databases/sqlite: no prebuilt SQLite library configured for this OS/ARCH. " +
		"Add one under sqlite/lib/<os>_<arch>/ and a matching branch in imports.odin.",
	)
}

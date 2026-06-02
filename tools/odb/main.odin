// odb — the odin-databases code-generation toolbox: one binary that dispatches
// to every generator in tools/ as a subcommand. It is a thin front door; each
// subcommand is the existing tool's `run` proc (which parses its own flags via
// core:flags), so `odb schema -h` and `odin run tools/schemagen -- -h` show the
// same flags. The standalone tools still build and run on their own.
//
// Usage:
//   odb <command> [flags] [args]
//   odb <command> -h          # flags for that command
//
// Commands:
//   scan         <dir>                 generate row scanners            (scangen)
//   schema       [flags] <dir>         generate typed descriptors       (schemagen)
//   migrate-new  <dir> <name>          scaffold a new migration pair    (migranew)
//   migrate-gen  [flags] <src> <dst>   embed .sql migrations            (migragen)
//   version                            print the odb version
package main

import "core:fmt"
import "core:os"

import migragen "database:tools/migragen"
import migranew "database:tools/migranew"
import scangen "database:tools/scangen"
import schemagen "database:tools/schemagen"

VERSION :: "0.1.0"

main :: proc() {
	if len(os.args) < 2 {
		usage(true)
		os.exit(2)
	}

	cmd := os.args[1]
	rest := os.args[2:]

	switch cmd {
	case "scan":
		os.exit(scangen.run("odb scan", rest))
	case "schema":
		os.exit(schemagen.run("odb schema", rest))
	case "migrate-gen", "migragen":
		os.exit(migragen.run("odb migrate-gen", rest))
	case "migrate-new", "migranew":
		os.exit(migranew.run("odb migrate-new", rest))
	case "version", "-version", "--version":
		fmt.printfln("odb %s", VERSION)
	case "help", "-h", "-help", "--help":
		usage(false)
	case:
		fmt.eprintfln("odb: unknown command %q", cmd)
		usage(true)
		os.exit(2)
	}
}

USAGE := []string {
	"odb — odin-databases code-generation toolbox",
	"",
	"usage: odb <command> [flags] [args]",
	"",
	"commands:",
	"  scan         <dir>                generate row scanners (scangen)",
	"  schema       [flags] <dir>        generate typed descriptors (schemagen)",
	"  migrate-new  <dir> <name>         scaffold a new migration pair (migranew)",
	"  migrate-gen  [flags] <src> <dst>  embed .sql migrations (migragen)",
	"  version                           print the odb version",
	"",
	"run 'odb <command> -h' for command-specific flags",
}

usage :: proc(to_stderr: bool) {
	for line in USAGE {
		if to_stderr {
			fmt.eprintln(line)
		} else {
			fmt.println(line)
		}
	}
}

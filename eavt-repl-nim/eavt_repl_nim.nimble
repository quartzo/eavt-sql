# Package

version       = "0.1.0"
author        = "fabio"
description   = "Interactive SQL REPL for EAVT databases (UDS client, pure Nim)"
license       = "MIT"
srcDir        = "src"
backend       = "c"

requires "nim >= 2.0.14"
requires "linenoise"

task release, "Build the REPL":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "--out:../build/eavt-sql-cli src/eavt_repl.nim"

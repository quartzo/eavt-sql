# Package

version       = "0.1.0"
author        = "fabio"
description   = "Interactive SQL REPL for EAVT databases (UDS client, pure Nim)"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.14"
requires "linenoise"

task build, "Build the REPL":
  exec "nim c --mm:arc --threads:on -d:release " &
       "--path:src " &
       "--out:eavt-repl-nim src/eavt_repl"

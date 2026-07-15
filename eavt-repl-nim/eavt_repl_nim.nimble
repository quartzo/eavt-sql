# Package

version       = "0.1.0"
author        = "fabio"
description   = "Interactive SQL REPL for EAVT databases (gRPC client, pure Nim)"
license       = "MIT"
srcDir        = "src"
bin           = @["eavt_repl"]

# Nim rejects hyphens in module names, so we compile as eavt_repl and rename
# the final binary to eavt-repl-nim.
after build:
  exec "mv -f eavt_repl eavt-repl-nim"

# Dependencies

requires "nim >= 2.0.14"
requires "grpc >= 0.1.20"
requires "linenoise"

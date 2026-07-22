# memtable.nimble
# Nimble definition for the MemTable engine (persistent treap).
#
# Test:
#   cd nim_memtable && nimble test

version       = "0.1.0"
author        = "eavt-sql-nim"
description   = "Persistent treap MemTable engine (COW snapshots)"
license       = "MIT"
srcDir        = "."
backend       = "c"

task test, "Run unit tests":
  exec "nim c --mm:arc --threads:on -d:release " &
       "-r tests.nim"

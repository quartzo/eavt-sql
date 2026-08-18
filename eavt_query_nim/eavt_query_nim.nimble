version       = "0.2.0"
author        = "fabio"
description   = "EAVT query server: compiles SQL to Scheme (chronos, single-thread), routes writes to the transactor"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.14"
requires "chronos >= 4.0.0"

task release, "Build the query server":
  exec "nim c --mm:orc --threads:on -d:release -d:useMalloc " &
       "--out:../build/eavt-sql-query server.nim"

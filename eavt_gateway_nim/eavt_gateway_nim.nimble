# Package

version       = "0.2.0"
author        = "fabio"
description   = "EAVT SQL gateway: compiles SQL to Scheme (chronos, single-thread), forwards to the data server"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.14"
requires "chronos >= 4.0.0"

task release, "Build the gateway":
  exec "nim c --mm:orc --threads:on -d:release -d:useMalloc " &
       "--out:../build/eavt-sql-gateway server.nim"

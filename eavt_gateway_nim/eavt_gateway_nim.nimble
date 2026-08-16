# Package

version       = "0.1.0"
author        = "fabio"
description   = "EAVT SQL gateway: compiles SQL to Scheme, forwards to the data server"
license       = "MIT"
srcDir        = "."
backend       = "c"

requires "nim >= 2.0.14"

task release, "Build the gateway":
  exec "nim c --mm:atomicArc --threads:on -d:release -d:useMalloc " &
       "--out:../build/eavt-sql-gateway server.nim"

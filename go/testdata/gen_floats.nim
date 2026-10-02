## gen_floats.nim — emits `bitpattern<TAB>$float` lines used as golden vectors
## for the Go FloatString port (go/internal/client/render.go).  Run:
##   nim c -r --hints:off --warnings:off go/testdata/gen_floats.nim > go/testdata/golden/floats.txt
import std/strutils

const vals = [
  0.0, -0.0,
  1.0, -1.0, 0.5, 1.5, 2.0, -3.25,
  0.1, 0.2, 0.3,
  1.0 / 3.0, 2.0 / 3.0,
  3.141592653589793,
  1000000.0, 12345.6789, 123456789.123,
  1.0e-1, 1.0e-2, 1.0e-3, 1.0e-4, 1.0e-5, 1.0e-6, 1.0e-7,
  9.9e-7, 1.5e-6, 2.5e-8, 1.0e-9, 1.0e-10, 2.5e-10,
  1.0e15, 1.0e16, 1.0e17, 1.0e18, 1.0e20,
  1.23e5,
  1234567890123456.0,
  1.234567890123456e15,
  1.0e-300, 1.0e300,
  1.7976931348623157e308,
  5.0e-324,
  Inf, NegInf, NaN,
]

for f in vals:
  echo toHex(cast[uint64](f), 16), "\t", $f

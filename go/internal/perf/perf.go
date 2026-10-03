// Package perf gates the optional nanosecond timing buckets that mirror the
// Nim `when perfCounters` instrumentation (off by default).  Counts are always
// kept; the per-call clock reads only happen when EAVT_PERF_COUNTERS is set,
// so the default path pays one branch per instrumented site.
package perf

import (
	"os"
	"sync/atomic"
)

var enabled atomic.Bool

func init() {
	v := os.Getenv("EAVT_PERF_COUNTERS")
	enabled.Store(v == "true" || v == "1")
}

// Enabled reports whether the nanosecond buckets are collected.
func Enabled() bool { return enabled.Load() }

// SetEnabled overrides the gate (tests).
func SetEnabled(v bool) { enabled.Store(v) }

// Package logutil is a minimal stderr logger (leaf module, std-only).  Port
// of nim_logutil/logutil.nim.
//
// Levels DEBUG < INFO < WARN < ERROR; threshold from EAVT_LOG
// (debug|info|warn|error; default info).  One timestamped line to stderr, all
// helpers safe to call from any goroutine (server callbacks, workers).
package logutil

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// Level is a log severity.
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
)

var (
	threshold = parseThreshold(os.Getenv("EAVT_LOG"))
	mu        sync.Mutex
)

func parseThreshold(v string) Level {
	switch strings.ToLower(v) {
	case "debug":
		return LevelDebug
	case "warn":
		return LevelWarn
	case "error":
		return LevelError
	default:
		return LevelInfo
	}
}

func label(l Level) string {
	switch l {
	case LevelDebug:
		return "DEBUG"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	}
	return "INFO"
}

// Enabled reports whether a level would be emitted.
func Enabled(l Level) bool { return l >= threshold }

func emit(l Level, scope, msg string) {
	if l < threshold {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	// Whitelisted swallow: if stderr itself is broken there is nowhere left to
	// report, and raising would turn every log call into a crash vector.
	_, _ = fmt.Fprintf(os.Stderr, "%s [%s] %s: %s\n",
		time.Now().UTC().Format("2006-01-02 15:04:05Z"), label(l), scope, msg)
}

// Debug logs at DEBUG.
func Debug(scope, msg string) { emit(LevelDebug, scope, msg) }

// Info logs at INFO.
func Info(scope, msg string) { emit(LevelInfo, scope, msg) }

// Warn logs at WARN.
func Warn(scope, msg string) { emit(LevelWarn, scope, msg) }

// Error logs at ERROR.
func Error(scope, msg string) { emit(LevelError, scope, msg) }

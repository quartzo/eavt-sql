## logutil.nim — minimal stderr logger (leaf module, std-only).
##
## House rule (AGENTS.md): every `except` either logs or interrupts — there
## is no silently ignored exception anywhere. These helpers make the "logs"
## half cheap and consistent at every layer (page store up to the REPL).
##
## Levels: DEBUG < INFO < WARN < ERROR. Threshold from EAVT_LOG
## (debug|info|warn|error; default info). Output goes to stderr, one line,
## timestamped. All procs are raises:[] and gcsafe so they can be called
## from server callbacks and worker paths alike.

import std/[syncio, strutils, os, times]

type
  LogLevel* = enum
    lvlDebug, lvlInfo, lvlWarn, lvlError

func parseThreshold(v: string): LogLevel =
  case v.toLowerAscii()
  of "debug": lvlDebug
  of "info": lvlInfo
  of "warn": lvlWarn
  of "error": lvlError
  else: lvlInfo

let gLogThreshold: LogLevel = parseThreshold(getEnv("EAVT_LOG", "info"))

proc writeLogLine(level: string; scope, msg: string) {.gcsafe, raises: [].} =
  # Whitelisted swallow: if stderr itself is broken there is nowhere left to
  # report — raising here would turn every log call into a crash vector.
  try:
    stderr.writeLine(now().utc.format("yyyy-MM-dd HH:mm:ss'Z '"),
                     "[", level, "] ", scope, ": ", msg)
  except CatchableError:
    discard

proc emit(levelStr: string; minLevel: LogLevel; scope, msg: string) {.
    gcsafe, raises: [].} =
  if minLevel >= gLogThreshold:
    writeLogLine(levelStr, scope, msg)

template logDebug*(scope, msg: string) =
  bind emit
  emit("DEBUG", lvlDebug, scope, msg)

template logInfo*(scope, msg: string) =
  bind emit
  emit("INFO", lvlInfo, scope, msg)

template logWarn*(scope, msg: string) =
  bind emit
  emit("WARN", lvlWarn, scope, msg)

template logError*(scope, msg: string) =
  bind emit
  emit("ERROR", lvlError, scope, msg)

func excMsg*(e: ref CatchableError): string {.inline.} =
  ## "RuntimeTypeName: message" for exception log lines.
  $e.name & ": " & e.msg

func excMsg*(e: ref Exception): string {.inline.} =
  ## Overload for trait methods whose inference is Exception.
  $e.name & ": " & e.msg

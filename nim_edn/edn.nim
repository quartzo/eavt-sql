## edn.nim — EDN reader producing SExpr values.
##
## Reads the Datomic-style tx-data subset of EDN:
##   vectors [..], lists (..), keywords :ns/name, symbols, ?vars,
##   strings, ints (incl. negative tempids), floats, true/false/nil, `_`.
##
## Maps {..} and sets #{..} are parsed (reader-level) so error messages
## are precise, but the wire rejects them (no consumer yet — see
## docs/tx-protocol.md §4).  A keyword's kwval holds the name WITHOUT the
## leading colon (":person/name" → kwval "person/name"), matching the
## canonical storage form (tx-protocol.md §8).
##
## The reader is fail-loud: malformed input raises EdnError with position.

import std/strutils
import scheme

type
  EdnError* = object of CatchableError

const
  Whitespace = {' ', '\t', '\n', '\r', ','}   # EDN allows comma as whitespace

proc skipWs(input: string; pos: var int) =
  while pos < input.len and input[pos] in Whitespace:
    inc pos

proc parseEdnValue(input: string; pos: var int): SExpr {.raises: [EdnError], gcsafe.}

proc parseEdnString(input: string; pos: var int): SExpr {.raises: [EdnError], gcsafe.} =
  ## pos sits on the opening quote.
  inc pos
  var s = ""
  while pos < input.len:
    let c = input[pos]
    if c == '"':
      inc pos
      return newStr(s)
    if c == '\\':
      if pos + 1 >= input.len:
        raise newException(EdnError, "edn: unterminated escape at end of input")
      let esc = input[pos + 1]
      inc pos, 2
      case esc
      of 'n': s.add '\n'
      of 't': s.add '\t'
      of 'r': s.add '\r'
      of '"': s.add '"'
      of '\\': s.add '\\'
      else:
        raise newException(EdnError, "edn: unsupported escape \\" & esc &
          " at pos " & $pos)
    else:
      s.add c
      inc pos
  raise newException(EdnError, "edn: unterminated string")

proc parseEdnAtom(input: string; pos: var int): SExpr {.raises: [EdnError], gcsafe.} =
  var start = pos
  while pos < input.len and input[pos] notin Whitespace and
        input[pos] notin {'(', ')', '[', ']', '{', '}', '"'}:
    inc pos
  let s = input[start ..< pos]
  if s.len == 0:
    raise newException(EdnError, "edn: empty atom at pos " & $start)
  if s == "nil": return newVoid()
  if s == "true": return newBool(true)
  if s == "false": return newBool(false)
  if s == "_": return newSymbol("_")
  if s.startsWith(':'):
    if s.len == 1:
      raise newException(EdnError, "edn: bare ':' at pos " & $start)
    return newKeyword(s[1 ..^ 1])
  try: return newInt(parseBiggestInt(s))
  except ValueError:
    # Grammar dispatch: int → float → symbol. Not an error path.
    try: return newFloat(parseFloat(s))
    except ValueError: return newSymbol(s)

proc parseEdnColl(input: string; pos: var int; closing: char;
                  what: string): seq[SExpr] {.raises: [EdnError], gcsafe.} =
  ## pos sits just past the opening delimiter.
  while true:
    skipWs(input, pos)
    if pos >= input.len:
      raise newException(EdnError, "edn: unterminated " & what)
    if input[pos] == closing:
      inc pos
      return result
    if input[pos] == '"':
      result.add parseEdnString(input, pos)
    else:
      result.add parseEdnValue(input, pos)

proc parseEdnValue(input: string; pos: var int): SExpr {.raises: [EdnError], gcsafe.} =
  skipWs(input, pos)
  if pos >= input.len:
    raise newException(EdnError, "edn: unexpected end of input")
  case input[pos]
  of '[':
    inc pos
    return newList(parseEdnColl(input, pos, ']', "vector"))
  of '(':
    inc pos
    return newList(parseEdnColl(input, pos, ')', "list"))
  of '{':
    raise newException(EdnError, "edn: maps not supported at pos " & $pos)
  of '#':
    if pos + 1 < input.len and input[pos + 1] == '{':
      raise newException(EdnError, "edn: sets not supported at pos " & $pos)
    raise newException(EdnError, "edn: unsupported dispatch #" & input[pos + 1] &
      " at pos " & $pos)
  of '"':
    return parseEdnString(input, pos)
  else:
    return parseEdnAtom(input, pos)

proc readEdn*(input: string): SExpr {.raises: [EdnError], gcsafe.} =
  ## Read a single EDN value from the whole input.  Trailing content
  ## (other than whitespace) is an error.
  var pos = 0
  result = parseEdnValue(input, pos)
  skipWs(input, pos)
  if pos != input.len:
    raise newException(EdnError, "edn: trailing content at pos " & $pos)

proc readEdnVector*(input: string): seq[SExpr] {.raises: [EdnError], gcsafe.} =
  ## Read a top-level vector `[op op ...]` and return its elements —
  ## the tx-data entry point (docs/tx-protocol.md §3.1).
  var pos = 0
  skipWs(input, pos)
  if pos >= input.len or input[pos] != '[':
    raise newException(EdnError, "edn: expected tx-data vector, got: " &
      (if pos < input.len: $input[pos] else: "<eof>"))
  inc pos
  result = parseEdnColl(input, pos, ']', "tx-data vector")
import std/strutils

type
  TokenType* = enum
    ttSELECT, ttWHERE, ttAND, ttOR, ttIN,
    ttUPSERT, ttAS, ttSET, ttDELETE, ttUPDATE, ttFROM,
    ttATTRIBUTE, ttMANY, ttONE, ttREF, ttBYTES,
    ttEXPLAIN, ttDATALOG, ttUNIQUE, ttPARTITION, ttHISTORY, ttSTAR,
    ttDOT, ttCOMMA, ttLPAREN, ttRPAREN,
    ttEQ, ttGT, ttLT, ttGTE, ttLTE, ttNEQ,
    ttPLUS, ttMINUS, ttSLASH, ttMOD,
    ttINTEGER, ttFLOAT, ttSTRING, ttALIAS, ttIDENT,
    ttPARAM, ttEOF

const
  TokenNames* = [
    "SELECT", "WHERE", "AND", "OR", "IN",
    "UPSERT", "AS", "SET", "DELETE", "UPDATE", "FROM",
    "ATTRIBUTE", "MANY", "ONE", "REF", "BYTES",
    "EXPLAIN", "DATALOG", "UNIQUE", "PARTITION", "HISTORY", "STAR",
    "DOT", "COMMA", "LPAREN", "RPAREN",
    "EQ", "GT", "LT", "GTE", "LTE", "NEQ",
    "PLUS", "MINUS", "SLASH", "MOD",
    "INTEGER", "FLOAT", "STRING", "ALIAS", "IDENT",
    "PARAM", "EOF",
  ]

type
  LexToken* = object
    tt*: TokenType
    value*: string
    pos*: int

  LexError* = object of CatchableError
    pos*: int

proc newLexError(msg: string, pos: int): ref LexError =
  new(result)
  result.msg = msg & " at position " & $pos
  result.pos = pos

func keywordType(word: string): TokenType =
  case toUpperAscii(word)
  of "SELECT": ttSELECT
  of "WHERE": ttWHERE
  of "AND": ttAND
  of "UPSERT": ttUPSERT
  of "AS": ttAS
  of "SET": ttSET
  of "DELETE": ttDELETE
  of "UPDATE": ttUPDATE
  of "FROM": ttFROM
  of "ATTRIBUTE": ttATTRIBUTE
  of "MANY": ttMANY
  of "ONE": ttONE
  of "REF": ttREF
  of "BYTES": ttBYTES
  of "EXPLAIN": ttEXPLAIN
  of "DATALOG": ttDATALOG
  of "OR": ttOR
  of "UNIQUE": ttUNIQUE
  of "IN": ttIN
  of "PARTITION": ttPARTITION
  of "HISTORY": ttHISTORY
  of "MOD": ttMOD
  else: ttIDENT

func isKeyword(word: string): bool =
  keywordType(word) != ttIDENT

func isDigit(c: char): bool =
  c in {'0'..'9'}

func isAlpha(c: char): bool =
  c in {'a'..'z', 'A'..'Z'}

func isIdentChar(c: char): bool =
  c.isAlpha or c.isDigit or c in {'_', ':', '/', '-'}

proc readParam(src: string, pos: var int, start: int): LexToken =
  inc pos
  if pos >= src.len or not src[pos].isDigit:
    raise newLexError("expected digit after '%'", pos)
  while pos < src.len and src[pos].isDigit:
    inc pos
  LexToken(tt: ttPARAM, value: src[start..<pos], pos: start)

proc readString(src: string, pos: var int, start: int): LexToken =
  inc pos
  var parts = ""
  while pos < src.len:
    if src[pos] == '\'':
      if pos + 1 < src.len and src[pos + 1] == '\'':
        parts.add('\'')
        inc pos, 2
      else:
        inc pos
        return LexToken(tt: ttSTRING, value: parts, pos: start)
    else:
      parts.add(src[pos])
      inc pos
  raise newLexError("unterminated string literal", start)

proc readNumber(src: string, pos: var int, start: int): LexToken =
  if src[pos] == '-':
    inc pos
  while pos < src.len and src[pos].isDigit:
    inc pos
  if pos < src.len and src[pos] == '.':
    inc pos
    while pos < src.len and src[pos].isDigit:
      inc pos
    LexToken(tt: ttFLOAT, value: src[start..<pos], pos: start)
  else:
    LexToken(tt: ttINTEGER, value: src[start..<pos], pos: start)

proc readIdentOrKeyword(src: string, pos: var int, start: int): LexToken =
  while pos < src.len and src[pos].isIdentChar:
    inc pos
  let word = src[start..<pos]
  let upper = toUpperAscii(word)
  if isKeyword(upper):
    LexToken(tt: keywordType(upper), value: word, pos: start)
  elif word.len >= 2 and word[0] == 'd':
    var allDigits = true
    for i in 1..<word.len:
      if not word[i].isDigit:
        allDigits = false
        break
    if allDigits:
      LexToken(tt: ttALIAS, value: word, pos: start)
    else:
      LexToken(tt: ttIDENT, value: word, pos: start)
  else:
    LexToken(tt: ttIDENT, value: word, pos: start)

proc tokenize*(source: string): seq[LexToken] =
  var pos = 0
  result = @[]
  let n = source.len

  template skipWhitespace =
    while pos < n and source[pos] in {' ', '\t', '\n', '\r'}:
      inc pos

  while pos < n:
    skipWhitespace
    if pos >= n: break

    let start = pos
    case source[pos]
    of '*':
      result.add LexToken(tt: ttSTAR, value: "*", pos: pos)
      inc pos
    of '+':
      result.add LexToken(tt: ttPLUS, value: "+", pos: pos)
      inc pos
    of '/':
      result.add LexToken(tt: ttSLASH, value: "/", pos: pos)
      inc pos
    of '.':
      result.add LexToken(tt: ttDOT, value: ".", pos: pos)
      inc pos
    of ',':
      result.add LexToken(tt: ttCOMMA, value: ",", pos: pos)
      inc pos
    of '(':
      result.add LexToken(tt: ttLPAREN, value: "(", pos: pos)
      inc pos
    of ')':
      result.add LexToken(tt: ttRPAREN, value: ")", pos: pos)
      inc pos
    of '!':
      if pos + 1 < n and source[pos + 1] == '=':
        result.add LexToken(tt: ttNEQ, value: "!=", pos: pos)
        inc pos, 2
      else:
        raise newLexError("unexpected character '!'", pos)
    of '=':
      result.add LexToken(tt: ttEQ, value: "=", pos: pos)
      inc pos
    of '>':
      if pos + 1 < n and source[pos + 1] == '=':
        result.add LexToken(tt: ttGTE, value: ">=", pos: pos)
        inc pos, 2
      else:
        result.add LexToken(tt: ttGT, value: ">", pos: pos)
        inc pos
    of '<':
      if pos + 1 < n and source[pos + 1] == '>':
        result.add LexToken(tt: ttNEQ, value: "<>", pos: pos)
        inc pos, 2
      elif pos + 1 < n and source[pos + 1] == '=':
        result.add LexToken(tt: ttLTE, value: "<=", pos: pos)
        inc pos, 2
      else:
        result.add LexToken(tt: ttLT, value: "<", pos: pos)
        inc pos
    of '%':
      result.add readParam(source, pos, start)
    of '\'':
      result.add readString(source, pos, start)
    of '0'..'9':
      result.add readNumber(source, pos, start)
    of '-':
      if pos + 1 < n and source[pos + 1].isDigit:
        result.add readNumber(source, pos, start)
      else:
        result.add LexToken(tt: ttMINUS, value: "-", pos: pos)
        inc pos
    of ':', '_', 'a'..'z', 'A'..'Z':
      result.add readIdentOrKeyword(source, pos, start)
    else:
      raise newLexError("unexpected character '" & source[pos] & "'", pos)

  result.add LexToken(tt: ttEOF, value: "", pos: pos)

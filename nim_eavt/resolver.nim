## resolver.nim — Nim Resolver (schema cache, ID allocation).
##
## Port of spier-transactor/src/resolver.rs (~340 lines Rust → Nim).
## Manages attribute registry, partition counters, and schema metadata.

import std/[tables, sets, strutils, options]

# ═══════════════════════════════════════════════════════════════════════════════
# Constants (from resolver_consts.rs)
# ═══════════════════════════════════════════════════════════════════════════════

const
  BootstrapFirstUserId* = 100'u64

  DbIdentAid* = 1'u32
  DbCardinalityAid* = 2'u32
  DbValueTypeAid* = 3'u32
  DbUniqueAid* = 5'u32
  DbIndexAid* = 6'u32
  DbTxInstantAid* = 9'u32
  DbPartIdAid* = 39'u32

  DbTypeString* = 20'u32
  DbTypeRef* = 21'u32
  DbTypeLong* = 22'u32
  DbTypeKeyword* = 23'u32
  DbTypeBoolean* = 24'u32
  DbTypeInstant* = 25'u32
  DbTypeBytes* = 26'u32
  DbTypeFloat* = 27'u32
  DbTypeBlob* = 28'u32

  DbCardinalityOneAid* = 35'u32
  DbCardinalityManyAid* = 36'u32
  DbUniqueValueAid* = 37'u32
  DbUniqueIdentityAid* = 38'u32

  PartDb* = 0'u64
  PartTx* = 3'u64
  PartUser* = 4'u64

  FirstCustomPartition = 64'u64
  PartitionShift = 44'u32
  SeqMask = 0xFFFFFFFFFFF'u64

# ═══════════════════════════════════════════════════════════════════════════════
# Entity ID helpers
# ═══════════════════════════════════════════════════════════════════════════════

proc partitionOf*(eid: int64): uint64 = cast[uint64](eid) shr PartitionShift
proc seqOf*(eid: int64): int64 = cast[int64](cast[uint64](eid) and SeqMask)
proc makeEntityId*(partitionId: uint64, seq: int64): int64 =
  cast[int64]((partitionId shl PartitionShift) or cast[uint64](seq))

# ═══════════════════════════════════════════════════════════════════════════════
# Attribute name normalization
# ═══════════════════════════════════════════════════════════════════════════════

proc normalizeAttr*(name: string): string =
  if name.len > 0 and name[0] == ':' and '/' in name:
    result = name[1..^1].replace('/', '.')
  elif '.' notin name:
    raise newException(ValueError,
      "attribute name must include namespace (e.g. 'company.name'), got " & name)
  else:
    result = name

# ═══════════════════════════════════════════════════════════════════════════════
# Bootstrap schema
# ═══════════════════════════════════════════════════════════════════════════════

const BootstrapSchema: array[26, (string, uint32)] = [
  ("db.ident", 1),
  ("db.cardinality", 2),
  ("db.valueType", 3),
  ("db.isComponent", 4),
  ("db.unique", 5),
  ("db.index", 6),
  ("db.fulltext", 7),
  ("db.noHistory", 8),
  ("db.txInstant", 9),
  ("db.type.string", 20),
  ("db.type.ref", 21),
  ("db.type.long", 22),
  ("db.type.keyword", 23),
  ("db.type.boolean", 24),
  ("db.type.instant", 25),
  ("db.type.bytes", 26),
  ("db.type.float", 27),
  ("db.type.blob", 28),
  ("db.cardinality.one", 35),
  ("db.cardinality.many", 36),
  ("db.unique.value", 37),
  ("db.unique.identity", 38),
  ("db.part/id", 39),
  ("db.part/db", 40),
  ("db.part/tx", 41),
  ("db.part/user", 42),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Resolver
# ═══════════════════════════════════════════════════════════════════════════════

type
  PartitionCounter = object
    nextSeq: int64

  Resolver* = object
    attrs: Table[string, uint32]
    attrsRev: Table[uint32, string]
    nextAid: uint32
    partitions: Table[uint64, PartitionCounter]
    partitionNames: Table[string, uint64]
    nextCustomPartition: uint64
    cardinality: Table[uint32, bool]
    declared: HashSet[uint32]
    valueTypes: Table[uint32, uint32]
    uniqueAttrs: HashSet[uint32]
    indexedAttrs: HashSet[uint32]
    ## Declaration order (attr names by ascending aid; partition names by
    ## ascending id). Needed to replay the schema into the Rust compiler
    ## engine so it assigns the SAME ids.
    attrDeclOrder*: seq[string]
    partDeclOrder*: seq[string]

proc newResolver*(): Resolver =
  result.nextAid = 1
  result.nextCustomPartition = FirstCustomPartition
  result.attrs = initTable[string, uint32]()
  result.attrsRev = initTable[uint32, string]()
  result.partitions = initTable[uint64, PartitionCounter]()
  result.partitionNames = initTable[string, uint64]()
  result.cardinality = initTable[uint32, bool]()
  result.declared = initHashSet[uint32]()
  result.valueTypes = initTable[uint32, uint32]()
  result.uniqueAttrs = initHashSet[uint32]()
  result.indexedAttrs = initHashSet[uint32]()

  for (name, aid) in BootstrapSchema:
    result.attrs[name] = aid
    result.attrsRev[aid] = name
    result.declared.incl aid
    if aid >= result.nextAid:
      result.nextAid = aid + 1

  result.valueTypes[DbValueTypeAid] = DbTypeRef
  result.valueTypes[DbCardinalityAid] = DbTypeRef
  result.valueTypes[DbUniqueAid] = DbTypeRef
  result.valueTypes[DbIdentAid] = DbTypeString
  result.valueTypes[DbPartIdAid] = DbTypeLong
  result.valueTypes[DbTxInstantAid] = DbTypeInstant
  result.indexedAttrs.incl DbIdentAid

  result.partitions[PartDb] = PartitionCounter(nextSeq: BootstrapFirstUserId.int64)
  result.partitionNames["db.part/db"] = PartDb
  result.partitions[PartTx] = PartitionCounter(nextSeq: 1)
  result.partitionNames["db.part/tx"] = PartTx
  result.partitions[PartUser] = PartitionCounter(nextSeq: 1)
  result.partitionNames["db.part/user"] = PartUser

# ── Partition management (must come before attr resolution — uses forward ref) ──

proc allocateInPartition*(r: var Resolver; partitionId: uint64): int64 =
  if partitionId notin r.partitions:
    raise newException(ValueError, "unknown partition: " & $partitionId)
  let seqVal = r.partitions[partitionId].nextSeq
  r.partitions[partitionId].nextSeq = seqVal + 1
  return makeEntityId(partitionId, cast[int64](seqVal))

proc allocateEntityId*(r: var Resolver): int64 =
  allocateInPartition(r, PartUser)

proc allocateSchemaId*(r: var Resolver): int64 =
  allocateInPartition(r, PartDb)

proc partitionIdFor*(r: var Resolver; name: string): Option[uint64] =
  if name in r.partitionNames: return some(r.partitionNames[name])

proc declarePartition*(r: var Resolver; name: string): uint64 =
  if name in r.partitionNames: return r.partitionNames[name]
  let p = r.nextCustomPartition
  inc r.nextCustomPartition
  r.partitions[p] = PartitionCounter(nextSeq: 1)
  r.partitionNames[name] = p
  r.partDeclOrder.add name
  return p

proc registerPartition*(r: var Resolver; name: string; partitionId: uint64) =
  if name in r.partitionNames: return
  if partitionId notin r.partitions:
    r.partitions[partitionId] = PartitionCounter(nextSeq: 1)
  r.partitionNames[name] = partitionId
  if partitionId >= FirstCustomPartition and partitionId >= r.nextCustomPartition:
    r.nextCustomPartition = partitionId + 1

proc defaultUserPartition*(r: var Resolver): uint64 = PartUser
proc knownPartitions*(r: var Resolver): seq[uint64] =
  for k in r.partitions.keys: result.add k

# ── Attribute resolution ──

proc lookupAttr*(r: var Resolver; name: string): Option[uint32] =
  try:
    let n = normalizeAttr(name)
    if n in r.attrs: return some(r.attrs[n])
  except: discard

proc isDeclared*(r: var Resolver; aid: uint32): bool = aid in r.declared

proc internAttr*(r: var Resolver; name: string): uint32 =
  let n = normalizeAttr(name)
  if n in r.attrs: return r.attrs[n]
  let eid = allocateInPartition(r, PartDb)
  let aid = eid.uint32
  r.nextAid = aid + 1
  r.attrs[n] = aid
  r.attrsRev[aid] = n
  return aid

proc declareAttr*(r: var Resolver; name: string; valueType: uint32;
                   many: bool): (uint32, bool) =
  let n = normalizeAttr(name)
  if n in r.attrs and r.attrs[n] in r.declared:
    return (r.attrs[n], false)
  let seqVal = allocateInPartition(r, PartDb)
  let aid = seqVal.uint32
  r.nextAid = aid + 1
  r.attrs[n] = aid
  r.attrsRev[aid] = n
  r.declared.incl aid
  r.valueTypes[aid] = valueType
  if many: r.cardinality[aid] = true
  r.attrDeclOrder.add n
  return (aid, true)

proc valueTypeFor*(r: var Resolver; aid: uint32): Option[uint32] =
  if aid in r.valueTypes: return some(r.valueTypes[aid])

proc attrName*(r: var Resolver; aid: uint32): string =
  r.attrsRev.getOrDefault(aid, $aid)

proc attrNameOpt*(r: var Resolver; aid: uint32): Option[string] =
  if aid in r.attrsRev: return some(r.attrsRev[aid])

# ── Cardinality / uniqueness / indexing ──

proc isMany*(r: var Resolver; aid: uint32): bool =
  aid in r.cardinality

proc setCardinality*(r: var Resolver; aid: uint32; many: bool) =
  if many: r.cardinality[aid] = true else: r.cardinality.del(aid)

proc isUnique*(r: var Resolver; aid: uint32): bool =
  aid in r.uniqueAttrs

proc setUnique*(r: var Resolver; aid: uint32; unique: bool) =
  if unique: r.uniqueAttrs.incl aid else: r.uniqueAttrs.excl aid

proc isIndexed*(r: var Resolver; aid: uint32): bool =
  aid in r.uniqueAttrs or aid in r.indexedAttrs

proc setIndexed*(r: var Resolver; aid: uint32; indexed: bool) =
  if indexed: r.indexedAttrs.incl aid else: r.indexedAttrs.excl aid

# ── Sequence management ──

proc advancePast*(r: var Resolver; eid: int64) =
  let p = partitionOf(eid)
  let s = seqOf(eid)
  if p in r.partitions:
    if s >= r.partitions[p].nextSeq:
      r.partitions[p].nextSeq = s + 1

proc setPartitionSeq*(r: var Resolver; partitionId: uint64, seq: int64) =
  if partitionId in r.partitions:
    if seq > r.partitions[partitionId].nextSeq:
      r.partitions[partitionId].nextSeq = seq

proc nextEntId*(r: var Resolver): int64 =
  if PartDb in r.partitions: return r.partitions[PartDb].nextSeq
  return BootstrapFirstUserId.int64

# ── Batch loading ──

proc loadAttrs*(r: var Resolver; items: seq[(seq[byte], seq[byte])]) =
  for (k, v) in items:
    let name = newString(k.len)
    if k.len > 0: copyMem(addr name[0], addr k[0], k.len)
    if v.len < 4: continue
    let aid = (uint32(v[0]) shl 24 or uint32(v[1]) shl 16 or
                uint32(v[2]) shl 8 or uint32(v[3]))
    r.attrs[name] = aid
    r.attrsRev[aid] = name
    if aid >= r.nextAid: r.nextAid = aid + 1

proc loadUserAttr*(r: var Resolver; name: string; eid: int64;
                    valueType: uint32; many, unique, indexed: bool) =
  let aid = eid.uint32
  let isNew = aid notin r.declared
  r.attrs[name] = aid
  r.attrsRev[aid] = name
  r.declared.incl aid
  r.valueTypes[aid] = valueType
  if many: r.cardinality[aid] = true
  if unique: r.uniqueAttrs.incl aid
  if indexed: r.indexedAttrs.incl aid
  if isNew:
    # keep attrDeclOrder sorted by aid (= declaration order in PartDb)
    var insPos = r.attrDeclOrder.len
    for i, n in r.attrDeclOrder:
      if r.attrs.getOrDefault(n, 0'u32) > aid: insPos = i; break
    r.attrDeclOrder.insert(name, insPos)
  let p = partitionOf(eid)
  if p in r.partitions:
    if seqOf(eid) >= r.partitions[p].nextSeq:
      r.partitions[p].nextSeq = seqOf(eid) + 1
  if aid >= r.nextAid: r.nextAid = aid + 1

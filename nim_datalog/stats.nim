import tables, sets, json
import std/streams
import msgpack4nim
import msgpack_scan

type
  CompileStats* = object
    attrIds*: Table[string, uint32]
    indexEstimates*: Table[string, float64]  # key: "EAVT:" or "AVET:100:"
    partitionIds*: Table[string, uint64]
    refAttrs*: HashSet[string]
    indexedAttrs*: HashSet[string]  # unique ∨ indexed — AVET is written only for these

proc statsToJson*(s: CompileStats): JsonNode =
  var attrs = newJObject()
  for k, v in s.attrIds: attrs[k] = %v
  var ests = newJObject()
  for k, v in s.indexEstimates: ests[k] = %v
  var parts = newJObject()
  for k, v in s.partitionIds: parts[k] = %v
  var refs = newJArray()
  for k in s.refAttrs: refs.add(%k)
  var idx = newJArray()
  for k in s.indexedAttrs: idx.add(%k)
  %*{"attrIds": attrs, "indexEstimates": ests,
     "partitionIds": parts, "refAttrs": refs, "indexedAttrs": idx}

proc statsFromJson*(n: JsonNode): CompileStats =
  result = CompileStats()
  for k, v in n["attrIds"]: result.attrIds[k] = uint32(v.getInt)
  for k, v in n["indexEstimates"]: result.indexEstimates[k] = v.getFloat
  for k, v in n["partitionIds"]: result.partitionIds[k] = uint64(v.getInt)
  for v in n["refAttrs"]: result.refAttrs.incl(v.getStr)
  if n.hasKey("indexedAttrs"):
    for v in n["indexedAttrs"]: result.indexedAttrs.incl(v.getStr)

proc statsToMsgpack*(s: CompileStats): string =
  ## Encode CompileStats directly to msgpack bytes (no JsonNode intermediate).
  var ms = MsgStream.init(256)
  ms.pack_map(5)
  ms.pack("attrIds"); ms.pack_map(s.attrIds.len)
  for k, v in s.attrIds: ms.pack(k); ms.pack(uint64(v))
  ms.pack("indexEstimates"); ms.pack_map(s.indexEstimates.len)
  for k, v in s.indexEstimates: ms.pack(k); ms.pack(v)
  ms.pack("partitionIds"); ms.pack_map(s.partitionIds.len)
  for k, v in s.partitionIds: ms.pack(k); ms.pack(v)
  ms.pack("refAttrs"); ms.pack_array(s.refAttrs.len)
  for k in s.refAttrs: ms.pack(k)
  ms.pack("indexedAttrs"); ms.pack_array(s.indexedAttrs.len)
  for k in s.indexedAttrs: ms.pack(k)
  ms.data

proc packStats*(ms: MsgStream; s: CompileStats) =
  ## Write CompileStats directly to an existing MsgStream.
  ms.pack_map(5)
  ms.pack("attrIds"); ms.pack_map(s.attrIds.len)
  for k, v in s.attrIds: ms.pack(k); ms.pack(uint64(v))
  ms.pack("indexEstimates"); ms.pack_map(s.indexEstimates.len)
  for k, v in s.indexEstimates: ms.pack(k); ms.pack(v)
  ms.pack("partitionIds"); ms.pack_map(s.partitionIds.len)
  for k, v in s.partitionIds: ms.pack(k); ms.pack(v)
  ms.pack("refAttrs"); ms.pack_array(s.refAttrs.len)
  for k in s.refAttrs: ms.pack(k)
  ms.pack("indexedAttrs"); ms.pack_array(s.indexedAttrs.len)
  for k in s.indexedAttrs: ms.pack(k)

proc statsFromMsgpack*(data: string): CompileStats =
  ## Decode CompileStats from raw msgpack bytes.
  result = CompileStats()
  let (af, aStart, ae) = topValue(data, "attrIds")
  if af:
    let s = MsgStream.init(data)
    s.setPosition(aStart)
    let count = s.unpack_map()
    for i in 0 ..< count:
      let kLen = s.unpack_string()
      let k = s.readExactStr(kLen)
      result.attrIds[k] = uint32(s.unpack_imp_uint64())
  let (ef, es, ee) = topValue(data, "indexEstimates")
  if ef:
    let s = MsgStream.init(data)
    s.setPosition(es)
    let count = s.unpack_map()
    for i in 0 ..< count:
      let kLen = s.unpack_string()
      let k = s.readExactStr(kLen)
      result.indexEstimates[k] = s.unpack_imp_float64()
  let (pf, ps, pe) = topValue(data, "partitionIds")
  if pf:
    let s = MsgStream.init(data)
    s.setPosition(ps)
    let count = s.unpack_map()
    for i in 0 ..< count:
      let kLen = s.unpack_string()
      let k = s.readExactStr(kLen)
      result.partitionIds[k] = s.unpack_imp_uint64()
  let (rf, rs, re) = topValue(data, "refAttrs")
  if rf:
    for (s, e) in topArrayElems(data, rs, re):
      let decoded = decodeStrAt(data, s, e)
      if decoded.len > 0: result.refAttrs.incl(decoded)
  let (xf, xs, xe) = topValue(data, "indexedAttrs")
  if xf:
    for (s, e) in topArrayElems(data, xs, xe):
      let decoded = decodeStrAt(data, s, e)
      if decoded.len > 0: result.indexedAttrs.incl(decoded)

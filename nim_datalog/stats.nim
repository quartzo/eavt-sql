import tables, sets, json

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

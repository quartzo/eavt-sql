import tables, sets

type
  CompileStats* = object
    attrIds*: Table[string, uint32]
    indexEstimates*: Table[string, float64]  # key: "EAVT:" or "AVET:100:"
    partitionIds*: Table[string, uint64]
    refAttrs*: HashSet[string]

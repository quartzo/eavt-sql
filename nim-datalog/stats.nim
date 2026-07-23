type
  CompileStats* = object
    lookupAttr*: proc(name: string): uint32
    estimateIndexSize*: proc(index: string, bound: openArray[uint64]): float64 {.nimcall.}
    partitionIdFor*: proc(name: string): uint64
    isRefAttr*: proc(name: string): bool
    isIndexedAttr*: proc(name: string): bool

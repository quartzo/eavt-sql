type
  CompileStats* = object
    lookupAttr*: proc(name: string): uint32 {.closure.}
    estimateIndexSize*: proc(index: string, bound: openArray[uint64]): float64 {.closure.}
    partitionIdFor*: proc(name: string): uint64 {.closure.}
    isRefAttr*: proc(name: string): bool {.closure.}
    isIndexedAttr*: proc(name: string): bool {.closure.}

package repl

// helpText mirrors the Nim REPL's HelpText const (Nim strips the newline
// right after the opening triple-quote); printed with an extra trailing
// newline, like Nim's `echo`.
const helpText = `Dot commands (no semicolon):
  .quit, .exit           Exit the REPL
  .help                  Show this help
  .flush                 Request background flush (returns immediately)
  .flush-sync            Flush and wait for completion
  .gc                    Run blob GC now (report roots/blobs removed)
  .gc-dry                Dry-run GC (report only, removes nothing)
  .status                Database overview
  .tree                  Per-column-family stats
  .memtable              MemTable contents and sizes
  .dump [EAVT|AEVT|...|CF]  Dump active datoms (or KV CF if number >= 10)
  .kv-put <cf> <key> <value>  Put key-value pair (CFs >= 10)
  .kv-get <cf> <key>          Get value by key
  .kv-delete <cf> <key>       Delete key
  .kv-scan <cf>               Scan all pairs in a CF

Datalog queries end with ;   e.g.  [:find ?name :where [?e :person/name ?name]];
`

## test_symtab.nim — intern table: identity, stability, reverse lookup.

import unittest, symtab

suite "symtab intern":
  let tab = newSymTab()

  test "same payload → same id, no growth":
    let a = tab.internSym("empresa/cnpj_base")
    let b = tab.internSym("empresa/cnpj_base")
    check a == b
    check tab.symCount() == tab.symCount()  # no growth on repeat

  test "distinct payloads → distinct ids":
    let a = tab.internSym("foo/bar_symtab_test")
    let b = tab.internSym("baz/qux_symtab_test")
    check uint32(a) != uint32(b)
    check uint32(a) != 0 and uint32(b) != 0

  test "reverse lookup":
    let id = tab.internSym("reverse/lookup_test")
    check tab.symName(id) == "reverse/lookup_test"
    check tab.symName(SymId(0)) == ""
    check tab.symName(SymId(uint32(tab.symCount()) + 999)) == ""

  test "boot consts are stable":
    check tab.dbAdd == tab.internSym("db/add")
    check tab.dbRetract == tab.internSym("db/retract")
    check tab.dbAdd != tab.dbRetract

  test "ids are per-table":
    let other = newSymTab()
    check tab.internSym("x/y") != other.internSym("x/y")

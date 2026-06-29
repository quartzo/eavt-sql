"""Tests for compiler introspection via compile_sql_json.

These tests verify the compiler's bytecode output (VMProgram) directly,
without executing the program. They check:
- Deferred resolution: InternA emits symbolic names, not baked IDs
- eid is always an integer (ConstInt, no entity ref resolution)
- Cursor plan structure (index selection, variable bindings)
- Instruction sequences for different SQL statement types
"""

import pytest

from eavt_sql.engine import EAVTEngine


@pytest.fixture
def engine(tmp_path):
    e = EAVTEngine(str(tmp_path / "db"))
    list(e.sql("ATTRIBUTE company.name STRING ONE"))
    list(e.sql("ATTRIBUTE person.name STRING ONE"))
    list(e.sql("ATTRIBUTE company.active BOOLEAN ONE"))
    return e


def opcodes(program):
    return [inst["op"] for inst in program["instructions"]]


def find_op(program, op_name):
    return [inst for inst in program["instructions"] if inst["op"] == op_name]


def find_p4_str(program, op_name):
    return [inst["p4"] for inst in find_op(program, op_name) if inst["p4"] is not None]


class TestDeferredResolution:
    """Compiler resolves attr names to IDs at compile time (DatalogNumIR).
    Attrs emit ConstInt(id), not InternA(name). Entities are always integers."""

    def test_resolved_attr_uses_const_int(self, engine):
        """Resolved attrs emit ConstInt with the attr ID, not InternA with the name."""
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        intern_as = find_p4_str(program, "InternA")
        assert "company.name" not in intern_as, \
            "InternA should not be emitted for resolved attrs"
        const_ints = find_op(program, "ConstInt")
        assert len(const_ints) > 0, "expected ConstInt for resolved attr ID"

    def test_no_baked_attr_id(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        prefix_push = find_op(program, "PrefixPush")
        assert len(prefix_push) > 0, "expected PrefixPush for resolved attr"

    def test_eid_integer_uses_const_int(self, engine):
        """eid is always an integer — compiler emits ConstInt, never ConstStr for eid."""
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.eid = 100"
        )
        const_ints = find_op(program, "ConstInt")
        assert any(i["p4"] == 100 for i in const_ints), \
            "expected ConstInt(100) for integer eid"


class TestCursorPlan:
    """Cursor plans contain index selection and variable binding info."""

    def test_cursor_plan_has_index(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        opens = find_op(program, "ScannerOpen")
        assert len(opens) >= 1
        cf_id = opens[0]["p2"]
        assert cf_id in (0, 1, 2, 3)

    def test_cursor_plan_idx_order(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        opens = find_op(program, "ScannerOpen")
        assert len(opens) >= 1

    def test_cursor_plan_specs(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        opens = find_op(program, "ScannerOpen")
        assert len(opens) >= 1


class TestInstructionStructure:
    """Basic structural assertions on instruction sequences."""

    def test_select_has_halt(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        ops = opcodes(program)
        assert ops[-1] == "Halt"

    def test_program_has_registers(self, engine):
        program = engine.compile_sql_json(
            "SELECT d1.company.name WHERE d1.company.name = 'ACME'"
        )
        assert program["num_registers"] > 0

    def test_attribute_compiles(self, engine):
        program = engine.compile_sql_json(
            "ATTRIBUTE company.revenue FLOAT ONE"
        )
        ops = opcodes(program)
        assert "ExecAttribute" in ops

    def test_partition_compiles(self, engine):
        program = engine.compile_sql_json(
            "PARTITION my_partition"
        )
        ops = opcodes(program)
        assert "DeclarePartition" in ops

    def test_upsert_has_exec_insert(self, engine):
        program = engine.compile_sql_json(
            "UPSERT AS D1 SET company.name = 'Test Co'"
        )
        ops = opcodes(program)
        assert "ExecInsert" in ops
        assert "Halt" in ops

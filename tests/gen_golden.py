"""Generate golden test file from the Rust SQL parser."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
from eavt_sql.sql_parse_client import SqlParseClient

client = SqlParseClient()

cases = [
    ("field_projection", "SELECT d1.eid"),
    ("star", "SELECT *"),
    ("star_with_where", "SELECT * WHERE d1.active = true"),
    ("condition_eq", "SELECT d1.eid WHERE d1.x = 'hello'"),
    ("condition_param", "SELECT d1.eid WHERE d1.eid = %1"),
    ("multi_projection", "SELECT d1.eid, d1.name, d1.tx WHERE d1.eid = %1"),
    ("history", "SELECT HISTORY d1.name WHERE d1.eid = %1"),
    ("exists_mode", "SELECT 1 WHERE d1.eid = %1 AND d1.partner = %2"),
    ("range_gt", "SELECT d1.name WHERE d1.price > 1000"),
    ("range_gte", "SELECT d1.name WHERE d1.price >= 3.14"),
    ("range_lt", "SELECT d1.name WHERE d1.price < 42"),
    ("range_lte", "SELECT d1.name WHERE d1.price <= 42"),
    ("neq", "SELECT d1.ns.attr WHERE d1.ns.val != %1"),
    ("neq_angle", "SELECT d1.ns.attr WHERE d1.ns.val <> %1"),
    ("in_params", "SELECT d1.ns.attr WHERE d1.ns.val IN (%1, %2, %3)"),
    ("in_literals", "SELECT d1.ns.attr WHERE d1.ns.val IN (10, 20, 30)"),
    ("in_mixed", "SELECT d1.ns.attr WHERE d1.ns.val IN (10, %1, 'hello')"),
    ("or_condition", "SELECT d1.name WHERE d1.eid = %1 OR d1.eid = %2"),
    ("join", "SELECT d2.name WHERE d1.eid = %1 AND d1.partner = d2.eid"),
    ("namespaced", "SELECT d1.company.name WHERE d1.company.hq = %1"),
    ("select_without_where", "SELECT d1.name"),
    ("select_literal_projection", "SELECT 42"),
    ("select_float_projection", "SELECT 3.14"),
    ("select_string_projection", "SELECT 'hello'"),
    ("upsert_new", "UPSERT AS D1 SET company.name = 'X'"),
    ("upsert_bare", "UPSERT SET company.name = 'Y'"),
    ("upsert_tx", "UPSERT AS TX SET tx.user = 'admin'"),
    ("upsert_explicit_eid", "UPSERT AS D1 = %1 SET ns.attr = 'val'"),
    ("upsert_lookup", "UPSERT AS D1 = eid('company.name', 'X') SET person.age = 30"),
    ("upsert_alias_ref", "UPSERT AS D1 SET company.partner = d2, AS D2 SET person.name = 'Bob'"),
    ("upsert_multi_clause", "UPSERT AS D1 SET ns.x = %1, AS D2 SET ns.y = %2"),
    ("upsert_multi_value", "UPSERT AS D1 SET ns.x = %1, ns.y = %2"),
    ("upsert_eid_in_value", "UPSERT AS D1 SET ns.x = eid('attr', %1)"),
    ("upsert_val_lookup", "UPSERT AS D1 SET ns.x = val(%1, 'attr')"),
    ("upsert_bool_true", "UPSERT AS D1 SET ns.active = true"),
    ("upsert_bool_false", "UPSERT AS D1 SET ns.active = false"),
    ("upsert_float", "UPSERT AS D1 SET ns.price = 3.14"),
    ("upsert_integer", "UPSERT AS D1 SET ns.count = 42"),
    ("update_simple", "UPDATE AS D1 SET ns.attr = 'new' WHERE d1.eid = %1"),
    ("update_multi_clause", "UPDATE AS D1 SET ns.x = %1 , AS D2 SET ns.y = 'hello' WHERE d1.eid = %2"),
    ("delete_simple", "DELETE WHERE d1.eid = 42 AND d1.ns.attr = 'hello'"),
    ("delete_with_param", "DELETE WHERE d1.eid = %1 AND d1.ns.attr = %2"),
    ("attribute_string_unique", "ATTRIBUTE company.name STRING ONE UNIQUE"),
    ("attribute_ref_many", "ATTRIBUTE company.partner REF MANY"),
    ("attribute_ref_many_not_unique", "ATTRIBUTE company.partner REF MANY"),
    ("attribute_one", "ATTRIBUTE company.name STRING ONE"),
    ("attribute_unique", "ATTRIBUTE company.name STRING UNIQUE"),
    ("partition", "PARTITION my-partition"),
    ("explain_select", "EXPLAIN SELECT d1.name WHERE d1.eid = %1"),
    ("explain_attribute", "EXPLAIN ATTRIBUTE ns.attr STRING MANY"),
    ("explain_upsert", "EXPLAIN UPSERT AS D1 SET ns.x = 'val'"),
    ("explain_update", "EXPLAIN UPDATE AS D1 SET ns.attr = 'new' WHERE d1.eid = %1"),
    ("explain_delete", "EXPLAIN DELETE WHERE d1.eid = %1"),
    ("datalog_select", "DATALOG SELECT d1.name WHERE d1.eid = %1"),
    ("condition_in_on_eq", "SELECT d1.ns.attr WHERE d1.ns.val = (10, %1, 'hello')"),
    ("select_history_no_where", "SELECT HISTORY d1.name"),
    ("upsert_val_with_param", "UPSERT AS D1 SET ns.x = val(%1, %2)"),
    ("select_d2_eid_as_condition", "SELECT d1.name WHERE d1.eid = d2"),
    ("select_d2_dotted_as_condition", "SELECT d1.name WHERE d1.eid = d2.eid"),
]

golden = []
for label, sql in cases:
    try:
        result = client.parse(sql)
        golden.append({"label": label, "sql": sql, "expected": result})
        print(f"  OK  {label}: {sql}")
    except Exception as e:
        golden.append({"label": label, "sql": sql, "error": True, "message": str(e)})
        print(f"  ERR {label}: {sql} => {e}")

output_path = Path(__file__).parent.parent / "nim-sql-parse" / "golden.json"
with open(output_path, "w") as f:
    json.dump(golden, f, indent=2, ensure_ascii=False)
print(f"\n{len(golden)} golden entries written to {output_path}")

import pytest
from datetime import datetime, timezone
from eavt_sql.engine import EAVTEngine


def _make_tx_ent(t: int) -> int:
    return (3 << 44) | t


def test_tx_join_datomic_style():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE cnpj.numero STRING ONE"))
    list(engine.sql("ATTRIBUTE cnpj.razao_social STRING ONE"))

    list(engine.sql(
        "UPSERT SET cnpj.numero = '12345678000199', cnpj.razao_social = 'Raisehands Data Architecture'"
    ))

    eid = list(engine.sql("SELECT d1.eid WHERE d1.cnpj.numero = '12345678000199'"))[0][0]
    tx_eid = list(engine.sql("SELECT d1.tx WHERE d1.eid = %1", eid))[0][0]

    tx_instant = list(engine.sql("SELECT d1.db.txInstant WHERE d1.eid = %1", tx_eid))[0][0]
    assert tx_instant is not None

    nome = list(engine.sql("SELECT d1.cnpj.razao_social WHERE d1.cnpj.numero = %1", '12345678000199'))[0][0]
    assert nome == "Raisehands Data Architecture"

    engine.close()


def test_tx_join_with_eid():
    engine = EAVTEngine(":memory:")
    list(engine.sql("ATTRIBUTE cnpj.numero STRING ONE"))
    list(engine.sql("ATTRIBUTE cnpj.razao_social STRING ONE"))

    list(engine.sql(
        "UPSERT SET cnpj.numero = '12345678000199', cnpj.razao_social = 'Raisehands Data Architecture'"
    ))

    rows = list(engine.sql(
        "SELECT d1.cnpj.razao_social, d2.db.txInstant "
        "WHERE d1.cnpj.numero = %1 AND d1.tx = d2.eid",
        '12345678000199',
    ))
    assert len(rows) == 1
    assert rows[0][0] == "Raisehands Data Architecture"
    assert rows[0][1] is not None
    engine.close()

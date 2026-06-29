from __future__ import annotations

from eavt_sql.engine import EAVTEngine


def _crash_drop(eng):
    try:
        del eng._engine
    except Exception:
        pass


def _open(tmp_path):
    return EAVTEngine(str(tmp_path / "test.db"))


class TestJournalRecovery:
    def test_unflushed_upsert_survives_reopen(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE company.name STRING ONE"))
        eng.flush()
        list(eng.sql("UPSERT SET company.name = 'Acme'"))
        _crash_drop(eng)

        eng2 = _open(tmp_path)
        rows = list(eng2.sql("SELECT d1.eid WHERE d1.company.name = 'Acme'"))
        assert len(rows) == 1
        eng2.close()

    def test_journal_cleared_after_flush(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE user.email STRING ONE"))
        eng.flush()

        list(eng.sql("UPSERT SET user.email = 'a@b.com'"))
        eng.flush()

        _crash_drop(eng)
        eng2 = _open(tmp_path)
        rows = list(eng2.sql("SELECT d1.eid WHERE d1.user.email = 'a@b.com'"))
        assert len(rows) == 1
        eng2.close()

    def test_multiple_unflushed_writes_recovered(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE item.name STRING ONE"))
        eng.flush()

        for i in range(5):
            list(eng.sql(f"UPSERT SET item.name = 'item-{i}'"))
        _crash_drop(eng)

        eng2 = _open(tmp_path)
        for i in range(5):
            rows = list(eng2.sql(f"SELECT d1.eid WHERE d1.item.name = 'item-{i}'"))
            assert len(rows) == 1, f"item-{i} must survive crash recovery"
        eng2.close()

    def test_ref_index_recovered_after_crash(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE company.name STRING ONE"))
        list(eng.sql("ATTRIBUTE company.partner STRING MANY"))
        eng.flush()

        list(eng.sql("UPSERT SET company.name = 'Acme'"))
        list(eng.sql("UPSERT SET company.partner = 'Partner1'"))
        _crash_drop(eng)

        eng2 = _open(tmp_path)
        rows = list(eng2.sql("SELECT d1.eid WHERE d1.company.partner = 'Partner1'"))
        assert len(rows) == 1
        eng2.close()

    def test_schema_declare_survives_crash(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE user.email STRING ONE"))
        _crash_drop(eng)

        eng2 = _open(tmp_path)
        list(eng2.sql("UPSERT SET user.email = 'test@test.com'"))
        rows = list(eng2.sql("SELECT d1.eid WHERE d1.user.email = 'test@test.com'"))
        assert len(rows) == 1
        eng2.close()

    def test_clean_close_no_journal_leak(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE company.name STRING ONE"))
        eng.flush()
        list(eng.sql("UPSERT SET company.name = 'Acme'"))
        eng.close()

        eng2 = _open(tmp_path)
        rows = list(eng2.sql("SELECT d1.eid WHERE d1.company.name = 'Acme'"))
        assert len(rows) == 1
        eng2.close()

    def test_read_only_recovers_journal(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE company.name STRING ONE"))
        eng.flush()
        list(eng.sql("UPSERT SET company.name = 'Acme'"))
        _crash_drop(eng)

        ro = EAVTEngine(str(tmp_path / "test.db"), read_only=True)
        rows = list(ro.sql("SELECT d1.eid WHERE d1.company.name = 'Acme'"))
        assert len(rows) == 1
        ro.close()

    def test_read_only_sees_flushed_and_unflushed(self, tmp_path):
        eng = _open(tmp_path)
        list(eng.sql("ATTRIBUTE item.name STRING ONE"))
        eng.flush()

        list(eng.sql("UPSERT SET item.name = 'flushed'"))
        eng.flush()
        list(eng.sql("UPSERT SET item.name = 'unflushed'"))
        _crash_drop(eng)

        ro = EAVTEngine(str(tmp_path / "test.db"), read_only=True)
        rows1 = list(ro.sql("SELECT d1.eid WHERE d1.item.name = 'flushed'"))
        rows2 = list(ro.sql("SELECT d1.eid WHERE d1.item.name = 'unflushed'"))
        assert len(rows1) == 1
        assert len(rows2) == 1
        ro.close()

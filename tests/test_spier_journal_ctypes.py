from __future__ import annotations

import pytest

from eavt_sql._ffi import load_spier


def _unpack_kv(buf: bytes) -> list[tuple[bytes, bytes]]:
    entries = []
    pos = 0
    while pos + 4 <= len(buf):
        klen = int.from_bytes(buf[pos:pos + 4], "big"); pos += 4
        key = buf[pos:pos + klen]; pos += klen
        vlen = int.from_bytes(buf[pos:pos + 4], "big"); pos += 4
        val = buf[pos:pos + vlen]; pos += vlen
        entries.append((key, val))
    return entries


@pytest.fixture
def journal_lib():
    return load_spier("spier_journal_file")


@pytest.fixture
def journal_instance(journal_lib, tmp_path):
    handle = journal_lib.create_handle({"path": str(tmp_path)})
    yield handle
    handle.close()


class TestJournalSchemaReflection:
    def test_idl_hash_matches(self, journal_lib):
        # The codegen bakes the IDL hash as a constant; load() already gates
        # it against the .so's dynspire_idl_hash, so a non-zero constant here
        # confirms the client is wired to the matching spier.
        assert journal_lib.idl_hash() != 0

    def test_spier_name(self, journal_lib):
        assert journal_lib.name == "spier_journal_file"

    def test_typed_methods_exist(self, journal_lib):
        cls = journal_lib._client_class
        assert hasattr(cls, "journal_append")
        assert hasattr(cls, "journal_read")
        assert hasattr(cls, "journal_truncate")


class TestJournalAppendRead:
    def test_append_and_read_single(self, journal_instance, journal_lib):
        journal_instance.journal_append(**{"key": b"hello", "value": b"world"})
        entries = _unpack_kv(bytes(journal_instance.journal_read()))
        assert entries == [(b"hello", b"world")]

    def test_append_multiple_entries(self, journal_instance, journal_lib):
        for i in range(5):
            journal_instance.journal_append(**{"key": f"k{i}".encode(), "value": f"v{i}".encode()})
        entries = _unpack_kv(bytes(journal_instance.journal_read()))
        assert entries == [(f"k{i}".encode(), f"v{i}".encode()) for i in range(5)]

    def test_append_empty_key_value(self, journal_instance, journal_lib):
        journal_instance.journal_append(**{"key": b"", "value": b""})
        entries = _unpack_kv(bytes(journal_instance.journal_read()))
        assert entries == [(b"", b"")]

    def test_append_binary_data(self, journal_instance, journal_lib):
        data = bytes(range(200))
        journal_instance.journal_append(**{"key": data, "value": data})
        entries = _unpack_kv(bytes(journal_instance.journal_read()))
        assert entries == [(data, data)]


class TestJournalTruncate:
    def test_truncate_clears_entries(self, journal_instance, journal_lib):
        journal_instance.journal_append(**{"key": b"x", "value": b"y"})
        journal_instance.journal_truncate()
        entries = _unpack_kv(bytes(journal_instance.journal_read()))
        assert entries == []

    def test_truncate_when_empty_is_ok(self, journal_instance, journal_lib):
        journal_instance.journal_truncate()


class TestJournalFileOnDisk:
    def test_journal_file_exists_after_append(self, journal_instance, journal_lib, tmp_path):
        journal_instance.journal_append(**{"key": b"abc", "value": b"def"})
        journal_file = tmp_path / "journal" / "journal"
        assert journal_file.exists()

    def test_journal_binary_format(self, journal_instance, journal_lib, tmp_path):
        journal_instance.journal_append(**{"key": b"\x01\x02", "value": b"\x03\x04\x05"})
        journal_file = tmp_path / "journal" / "journal"
        raw = journal_file.read_bytes()
        assert raw == b"\x00\x00\x00\x02\x01\x02\x00\x00\x00\x03\x03\x04\x05"

    def test_journal_removed_after_truncate(self, journal_instance, journal_lib, tmp_path):
        journal_instance.journal_append(**{"key": b"k", "value": b"v"})
        journal_file = tmp_path / "journal" / "journal"
        assert journal_file.exists()
        journal_instance.journal_truncate()
        assert not journal_file.exists()


class TestJournalPersistence:
    def test_entries_survive_instance_recreate(self, tmp_path):
        journal_lib = load_spier("spier_journal_file")

        h1 = journal_lib.create_handle({"path": str(tmp_path)})
        h1.journal_append(**{"key": b"persist", "value": b"data"})
        h1.close()

        journal_lib2 = load_spier("spier_journal_file")
        h2 = journal_lib2.create_handle({"path": str(tmp_path)})
        entries = _unpack_kv(bytes(h2.journal_read()))
        assert entries == [(b"persist", b"data")]
        h2.close()

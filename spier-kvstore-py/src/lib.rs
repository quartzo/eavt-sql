use std::collections::HashMap;
use std::sync::Arc;

use pyo3::prelude::*;
use pyo3::types::PyDict;

use spier_journal_file::JournalFile;
use spier_kvstore::KVState;
use spier_storage_traits::{CursorHandle, JournalEngine, KVStoreEngine};

fn to_string_err(e: String) -> PyErr {
    pyo3::exceptions::PyRuntimeError::new_err(e)
}

#[pyclass(name = "CursorHandle", unsendable)]
pub struct PyCursorHandle {
    inner: CursorHandle,
}

/// Raw KVStore binding — exposes KVState directly with no EAVT/Transactor logic.
/// Use this for KV-level tests and low-level inspection.
#[pyclass(name = "Engine")]
pub struct PyKVEngine {
    inner: KVState,
}

#[pymethods]
impl PyKVEngine {
    #[new]
    #[pyo3(signature = (config=None))]
    fn new(py: Python<'_>, config: Option<&Bound<'_, PyDict>>) -> PyResult<Self> {
        let mut cfg: HashMap<String, String> = HashMap::new();
        if let Some(d) = config {
            for (k, v) in d.iter() {
                let key = k.extract::<String>()?;
                let val = v.str()?.to_string_lossy().into_owned();
                cfg.insert(key, val);
            }
        }
        let inner = py
            .allow_threads(|| KVState::open(&cfg))
            .map_err(to_string_err)?;
        Ok(Self { inner })
    }

    // KV writes
    #[pyo3(signature = (cf, key))]
    fn put(&self, py: Python<'_>, cf: u32, key: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.put(cf, key))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, keys))]
    fn batch_put(&self, py: Python<'_>, cf: u32, keys: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.batch_put(cf, keys))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (ops))]
    fn batch_write(&self, py: Python<'_>, ops: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.batch_write(ops))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, keys))]
    fn replay(&self, py: Python<'_>, cf: u32, keys: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.replay(cf, keys))
            .map_err(to_string_err)
    }

    // KV reads
    #[pyo3(signature = (cf, key))]
    fn get(&self, py: Python<'_>, cf: u32, key: &[u8]) -> PyResult<bool> {
        py.allow_threads(|| self.inner.get(cf, key))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, prefix))]
    fn scan(&self, py: Python<'_>, cf: u32, prefix: &[u8]) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.scan(cf, prefix))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, prefix))]
    fn scan_reverse(&self, py: Python<'_>, cf: u32, prefix: &[u8]) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.scan_reverse(cf, prefix))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf))]
    fn items(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.items(cf))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, prefix))]
    fn open_cursor_direct(
        &self,
        py: Python<'_>,
        cf: u32,
        prefix: &[u8],
    ) -> PyResult<PyCursorHandle> {
        py.allow_threads(|| self.inner.open_cursor_direct(cf, prefix))
            .map(|inner| PyCursorHandle { inner })
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, prefix))]
    fn open_cursor_reverse_direct(
        &self,
        py: Python<'_>,
        cf: u32,
        prefix: &[u8],
    ) -> PyResult<PyCursorHandle> {
        py.allow_threads(|| self.inner.open_cursor_reverse_direct(cf, prefix))
            .map(|inner| PyCursorHandle { inner })
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor))]
    fn cursor_valid(&self, py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) -> PyResult<bool> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| self.inner.cursor_valid(handle))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor))]
    fn cursor_current_key(
        &self,
        py: Python<'_>,
        cursor: &Bound<'_, PyCursorHandle>,
    ) -> PyResult<(bool, Vec<Vec<u8>>)> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| {
            let mut buf = Vec::new();
            self.inner
                .cursor_current_key(handle, &mut buf)
                .map(|ok| (ok, vec![buf]))
        })
        .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor))]
    fn cursor_step(&self, py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) -> PyResult<()> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| self.inner.cursor_step(handle))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor, target))]
    fn cursor_seek(
        &self,
        py: Python<'_>,
        cursor: &Bound<'_, PyCursorHandle>,
        target: &[u8],
    ) -> PyResult<()> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| self.inner.cursor_seek(handle, target))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor, group_end))]
    fn cursor_skip_group(
        &self,
        py: Python<'_>,
        cursor: &Bound<'_, PyCursorHandle>,
        group_end: u32,
    ) -> PyResult<()> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| self.inner.cursor_skip_group(handle, group_end))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cursor, end))]
    fn cursor_update_end(
        &self,
        py: Python<'_>,
        cursor: &Bound<'_, PyCursorHandle>,
        end: &[u8],
    ) -> PyResult<()> {
        let handle = cursor.borrow().inner.clone();
        py.allow_threads(|| self.inner.cursor_update_end(handle, end))
            .map_err(to_string_err)
    }

    // Journal
    #[pyo3(signature = (key, value))]
    fn journal_put(&self, py: Python<'_>, key: &[u8], value: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.journal_put(key, value))
            .map_err(to_string_err)
    }

    fn journal_scan(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.journal_scan())
            .map_err(to_string_err)
    }

    fn journal_size(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.journal_size())
            .map_err(to_string_err)
    }

    // Admin
    fn flush(&self, py: Python<'_>) -> PyResult<()> {
        py.allow_threads(|| self.inner.flush())
            .map_err(to_string_err)
    }

    fn close(&self, py: Python<'_>) -> PyResult<()> {
        py.allow_threads(|| self.inner.close())
            .map_err(to_string_err)
    }

    fn path(&self, py: Python<'_>) -> PyResult<String> {
        py.allow_threads(|| self.inner.path())
            .map_err(to_string_err)
    }

    fn memtable_size(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.memtable_size())
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf))]
    fn memtable_count(&self, py: Python<'_>, cf: u32) -> PyResult<u64> {
        py.allow_threads(|| self.inner.memtable_count(cf))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf, start, end))]
    fn approximate_sizes(
        &self,
        py: Python<'_>,
        cf: u32,
        start: &[u8],
        end: &[u8],
    ) -> PyResult<u64> {
        py.allow_threads(|| self.inner.approximate_sizes(cf, start, end))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (cf))]
    fn cf_stats(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.cf_stats(cf))
            .map_err(to_string_err)
    }

    fn db_stats(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.db_stats())
            .map_err(to_string_err)
    }

    #[pyo3(signature = (dry_run, nowait))]
    fn gc_full(&self, py: Python<'_>, dry_run: bool, nowait: bool) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.gc_full(dry_run, nowait))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (target=""))]
    fn internal_status(&self, py: Python<'_>, target: &str) -> PyResult<String> {
        py.allow_threads(|| self.inner.internal_status(target))
            .map_err(to_string_err)
    }
}

// Silence unused import warning — Arc is used implicitly via CursorHandle.
#[allow(dead_code)]
const _USE_ARC: fn() = || {
    let _: Option<Arc<()>> = None;
};

#[pyclass(name = "Journal")]
pub struct PyJournal {
    inner: JournalFile,
}

#[pymethods]
impl PyJournal {
    #[new]
    #[pyo3(signature = (config=None))]
    fn new(py: Python<'_>, config: Option<&Bound<'_, PyDict>>) -> PyResult<Self> {
        let mut cfg: HashMap<String, String> = HashMap::new();
        if let Some(d) = config {
            for (k, v) in d.iter() {
                let key = k.extract::<String>()?;
                let val = v.str()?.to_string_lossy().into_owned();
                cfg.insert(key, val);
            }
        }
        let inner = py
            .allow_threads(|| JournalFile::new(&cfg))
            .map_err(to_string_err)?;
        Ok(Self { inner })
    }

    #[pyo3(signature = (key, value))]
    fn journal_append(&self, py: Python<'_>, key: &[u8], value: &[u8]) -> PyResult<()> {
        py.allow_threads(|| self.inner.journal_append(key, value))
            .map_err(to_string_err)
    }

    fn journal_read(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.journal_read())
            .map_err(to_string_err)
    }

    fn journal_truncate(&self, py: Python<'_>) -> PyResult<()> {
        py.allow_threads(|| self.inner.journal_truncate())
            .map_err(to_string_err)
    }

    fn close(&self) {}
}

#[pymodule]
fn spier_kvstore_py(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyKVEngine>()?;
    m.add_class::<PyCursorHandle>()?;
    m.add_class::<PyJournal>()?;
    Ok(())
}

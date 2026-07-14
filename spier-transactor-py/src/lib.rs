use std::collections::HashMap;

use pyo3::prelude::*;
use pyo3::types::PyDict;

use spier_journal_file::JournalFile;
use spier_storage_traits::CursorHandle;
use spier_storage_traits::JournalEngine;
use spier_transactor::TransactorEngine;
use spier_transactor::TransactorState;
use spier_transactor::ValueType;
use spier_value::Value;

fn to_string_err(e: String) -> PyErr {
    pyo3::exceptions::PyRuntimeError::new_err(e)
}

fn parse_value_type(name: &str) -> PyResult<ValueType> {
    match name.to_uppercase().as_str() {
        "STRING" => Ok(ValueType::String),
        "REF" => Ok(ValueType::Ref),
        "LONG" => Ok(ValueType::Long),
        "KEYWORD" => Ok(ValueType::Keyword),
        "BOOLEAN" => Ok(ValueType::Boolean),
        "INSTANT" => Ok(ValueType::Instant),
        "BYTES" => Ok(ValueType::Bytes),
        "BLOB" => Ok(ValueType::Blob),
        "FLOAT" => Ok(ValueType::Float),
        _ => Err(pyo3::exceptions::PyValueError::new_err(format!(
            "unknown value type: {}",
            name
        ))),
    }
}

fn py_to_value(v: &Bound<'_, pyo3::types::PyAny>) -> PyResult<Value> {
    if v.is_instance_of::<pyo3::types::PyBool>() {
        return Ok(Value::Bool(v.extract::<bool>()? as u8));
    }
    if v.is_instance_of::<pyo3::types::PyInt>() {
        return Ok(Value::Int64(v.extract::<i64>()?));
    }
    if v.is_instance_of::<pyo3::types::PyFloat>() {
        return Ok(Value::Float64(v.extract::<f64>()?));
    }
    if v.is_instance_of::<pyo3::types::PyString>() {
        return Ok(Value::Text(v.extract::<String>()?));
    }
    if v.is_instance_of::<pyo3::types::PyBytes>() {
        return Ok(Value::Bytes(v.extract::<Vec<u8>>()?));
    }
    Err(pyo3::exceptions::PyTypeError::new_err(format!(
        "unsupported value type: {:?}",
        v.get_type()
    )))
}

#[pyclass(name = "CursorHandle", unsendable)]
pub struct PyCursorHandle {
    inner: CursorHandle,
}

#[pyclass(name = "Engine")]
pub struct PyEngine {
    inner: TransactorState,
}

#[pymethods]
impl PyEngine {
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
            .allow_threads(|| TransactorState::open(&cfg))
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

    // EAVT
    #[pyo3(signature = (e_id, attr, v, t, as_of_us))]
    fn eavt_save(
        &self,
        py: Python<'_>,
        e_id: u64,
        attr: &str,
        v: &Bound<'_, pyo3::types::PyAny>,
        t: u64,
        as_of_us: u64,
    ) -> PyResult<()> {
        let value = py_to_value(v)?;
        py.allow_threads(|| self.inner.eavt_save(e_id, attr, value, t, as_of_us))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (e_id, attr, v, current_t, as_of_us))]
    fn eavt_retract(
        &self,
        py: Python<'_>,
        e_id: u64,
        attr: &str,
        v: &Bound<'_, pyo3::types::PyAny>,
        current_t: u64,
        as_of_us: u64,
    ) -> PyResult<()> {
        let value = py_to_value(v)?;
        py.allow_threads(|| {
            self.inner
                .eavt_retract(e_id, attr, value, current_t, as_of_us)
        })
        .map_err(to_string_err)
    }

    #[pyo3(signature = (name, value_type, many, current_t))]
    fn eavt_declare_attr(
        &self,
        py: Python<'_>,
        name: &str,
        value_type: &str,
        many: bool,
        current_t: u64,
    ) -> PyResult<u32> {
        let vt = parse_value_type(value_type)?;
        py.allow_threads(|| self.inner.eavt_declare_attr(name, vt, many, current_t))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (attr, type_name, many, unique, current_t))]
    fn eavt_declare_attr_from_sql(
        &self,
        py: Python<'_>,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
        current_t: u64,
    ) -> PyResult<()> {
        py.allow_threads(|| {
            self.inner
                .eavt_declare_attr_from_sql(attr, type_name, many, unique, current_t)
        })
        .map_err(to_string_err)
    }

    #[pyo3(signature = (name, current_t))]
    fn eavt_declare_partition(&self, py: Python<'_>, name: &str, current_t: u64) -> PyResult<u64> {
        py.allow_threads(|| self.inner.eavt_declare_partition(name, current_t))
            .map_err(to_string_err)
    }

    fn eavt_allocate_tx(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.eavt_allocate_tx())
            .map_err(to_string_err)
    }

    #[pyo3(signature = (name))]
    fn lookup_attr(&self, py: Python<'_>, name: &str) -> PyResult<Option<u32>> {
        py.allow_threads(|| self.inner.lookup_attr(name))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (aid))]
    fn is_declared(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_declared(aid))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (aid))]
    fn attr_name(&self, py: Python<'_>, aid: u32) -> PyResult<String> {
        py.allow_threads(|| self.inner.attr_name(aid))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (aid))]
    fn value_type_for(&self, py: Python<'_>, aid: u32) -> PyResult<Option<String>> {
        py.allow_threads(|| self.inner.value_type_for(aid))
            .map_err(to_string_err)
            .map(|opt| opt.map(|vt| format!("{:?}", vt)))
    }

    #[pyo3(signature = (aid))]
    fn is_many(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_many(aid))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (aid))]
    fn is_unique(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_unique(aid))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (name))]
    fn is_unique_attr(&self, py: Python<'_>, name: &str) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_unique_attr(name))
            .map_err(to_string_err)
    }

    fn default_user_partition(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.default_user_partition())
            .map_err(to_string_err)
    }

    #[pyo3(signature = (name))]
    fn partition_id_for(&self, py: Python<'_>, name: &str) -> PyResult<Option<u64>> {
        py.allow_threads(|| self.inner.partition_id_for(name))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (attr_name, value))]
    fn lookup_entity(
        &self,
        py: Python<'_>,
        attr_name: &str,
        value: &Bound<'_, pyo3::types::PyAny>,
    ) -> PyResult<Option<u64>> {
        let v = py_to_value(value)?;
        py.allow_threads(|| self.inner.lookup_entity(attr_name, v))
            .map_err(to_string_err)
    }

    fn allocate_entity_id(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_entity_id())
            .map_err(to_string_err)
    }

    #[pyo3(signature = (partition_id))]
    fn allocate_in_partition(&self, py: Python<'_>, partition_id: u64) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_in_partition(partition_id))
            .map_err(to_string_err)
    }

    fn allocate_t(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_t())
            .map_err(to_string_err)
    }
}

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
fn spier_transactor_py(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyEngine>()?;
    m.add_class::<PyCursorHandle>()?;
    m.add_class::<PyJournal>()?;
    Ok(())
}

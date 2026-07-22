use std::collections::HashMap;
use std::sync::Mutex;

use pyo3::prelude::*;
use pyo3::types::PyDict;

use spier_eavt_query::QueryEngine;
use spier_eavt_query::QueryState;
use spier_page_store_nim::storage_traits::Cursor;
use spier_query_ir::ProgramHandle;
use spier_page_store_nim::transactor::ValueType;
use spier_value::Value;

struct SimpleCursor {
    keys: Vec<Vec<u8>>,
    idx: usize,
    valid: bool,
}

impl Cursor for SimpleCursor {
    fn is_valid(&self) -> bool { self.valid }
    fn current_key(&self) -> Option<&[u8]> {
        if self.valid { Some(&self.keys[self.idx]) } else { None }
    }
    fn step(&mut self) {
        if self.valid { self.idx += 1; self.valid = self.idx < self.keys.len(); }
    }
    fn skip_group(&mut self, _group_end: usize) { self.step(); }
    fn seek(&mut self, target: &[u8]) {
        self.idx = self.keys.partition_point(|k| k.as_slice() < target);
        self.valid = self.idx < self.keys.len();
    }
    fn update_end(&mut self, _end: &[u8]) {}
    fn invalidate(&mut self) { self.valid = false; }
}

/// Cursor for reverse-scan results (keys in descending order).
struct ReverseCursor {
    keys: Vec<Vec<u8>>,
    idx: usize,
    valid: bool,
}

impl Cursor for ReverseCursor {
    fn is_valid(&self) -> bool { self.valid }
    fn current_key(&self) -> Option<&[u8]> {
        if self.valid { Some(&self.keys[self.idx]) } else { None }
    }
    fn step(&mut self) {
        if self.valid { self.idx += 1; self.valid = self.idx < self.keys.len(); }
    }
    fn skip_group(&mut self, _group_end: usize) { self.step(); }
    fn seek(&mut self, target: &[u8]) {
        // Keys descending: find first key <= target
        self.idx = self.keys.partition_point(|k| k.as_slice() > target);
        self.valid = self.idx < self.keys.len();
    }
    fn update_end(&mut self, _end: &[u8]) {}
    fn invalidate(&mut self) { self.valid = false; }
}
unsafe impl Send for SimpleCursor {}
unsafe impl Send for ReverseCursor {}

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

/// Opaque handle to a compiled VM program.
#[pyclass(name = "ProgramHandle", unsendable)]
pub struct PyProgramHandle {
    inner: ProgramHandle,
}

/// Opaque handle to a streaming VM session.
#[pyclass(name = "SessionHandle", unsendable)]
pub struct PySessionHandle {
    inner: spier_eavt_query::SessionHandle,
}

/// Opaque handle to a raw KV cursor.
#[pyclass(name = "CursorHandle", unsendable)]
pub struct PyCursorHandle {
    inner: spier_page_store_nim::storage_traits::CursorHandle,
}

/// PyO3 bindings for spier-eavt-query.
#[pyclass(name = "Engine")]
pub struct PyEngine {
    inner: QueryState,
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
            .allow_threads(|| QueryState::open(&cfg))
            .map_err(to_string_err)?;
        Ok(Self { inner })
    }

    fn compile_sql(&self, py: Python<'_>, sql: &str, params: &[u8]) -> PyResult<PyProgramHandle> {
        py.allow_threads(|| self.inner.compile_sql(sql, params))
            .map(|inner| PyProgramHandle { inner })
            .map_err(to_string_err)
    }

    #[pyo3(signature = (program, params, limit, as_of_us))]
    fn run_vm(
        &self,
        py: Python<'_>,
        program: &Bound<'_, PyProgramHandle>,
        params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> PyResult<Vec<u8>> {
        let prog = program.borrow().inner.clone();
        py.allow_threads(|| self.inner.execute(prog, params, limit, as_of_us))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (program, params, limit, as_of_us))]
    fn run_vm_cursor(
        &self,
        py: Python<'_>,
        program: &Bound<'_, PyProgramHandle>,
        params: &[u8],
        limit: u64,
        as_of_us: u64,
    ) -> PyResult<PySessionHandle> {
        let prog = program.borrow().inner.clone();
        py.allow_threads(|| self.inner.open_cursor(prog, params, limit, as_of_us))
            .map(|inner| PySessionHandle { inner })
            .map_err(to_string_err)
    }

    #[pyo3(signature = (session, max_rows))]
    fn session_next_batch(
        &self,
        py: Python<'_>,
        session: &Bound<'_, PySessionHandle>,
        max_rows: u64,
    ) -> PyResult<Vec<u8>> {
        let handle = session.borrow().inner.clone();
        py.allow_threads(|| self.inner.session_next_batch(handle, max_rows))
            .map_err(to_string_err)
    }

    fn explain(&self, py: Python<'_>, sql: &str, params: &[u8]) -> PyResult<String> {
        py.allow_threads(|| self.inner.explain(sql, params))
            .map_err(to_string_err)
    }

    fn compile_sql_json(&self, py: Python<'_>, sql: &str, params: &[u8]) -> PyResult<String> {
        py.allow_threads(|| self.inner.compile_sql_json(sql, params))
            .map_err(to_string_err)
    }

    fn scan_datoms(&self, py: Python<'_>, as_of_us: u64) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.scan_datoms(as_of_us))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (name, value_type, many))]
    fn declare_attr(
        &self,
        py: Python<'_>,
        name: &str,
        value_type: &str,
        many: bool,
    ) -> PyResult<u32> {
        let vt = parse_value_type(value_type)?;
        py.allow_threads(|| self.inner.declare_attr(name, vt, many))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (attr, type_name, many, unique))]
    fn declare_attr_from_sql(
        &self,
        py: Python<'_>,
        attr: &str,
        type_name: &str,
        many: bool,
        unique: bool,
    ) -> PyResult<()> {
        py.allow_threads(|| {
            self.inner
                .declare_attr_from_sql(attr, type_name, many, unique)
        })
        .map_err(to_string_err)
    }

    fn lookup_attr(&self, py: Python<'_>, name: &str) -> PyResult<Option<u32>> {
        py.allow_threads(|| self.inner.lookup_attr(name))
            .map_err(to_string_err)
    }

    fn attr_name(&self, py: Python<'_>, aid: u32) -> PyResult<String> {
        py.allow_threads(|| self.inner.attr_name(aid))
            .map_err(to_string_err)
    }

    fn is_declared(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_declared(aid))
            .map_err(to_string_err)
    }

    fn value_type_for(&self, py: Python<'_>, aid: u32) -> PyResult<Option<String>> {
        py.allow_threads(|| self.inner.value_type_for(aid))
            .map_err(to_string_err)
            .map(|opt| opt.map(|vt| format!("{:?}", vt)))
    }

    fn is_many(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_many(aid))
            .map_err(to_string_err)
    }

    fn is_unique_attr(&self, py: Python<'_>, name: &str) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_unique_attr(name))
            .map_err(to_string_err)
    }

    fn declare_partition(&self, py: Python<'_>, name: &str) -> PyResult<u64> {
        py.allow_threads(|| self.inner.declare_partition(name))
            .map_err(to_string_err)
    }

    fn partition_id_for(&self, py: Python<'_>, name: &str) -> PyResult<Option<u64>> {
        py.allow_threads(|| self.inner.partition_id_for(name))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (e, attr, v, t))]
    fn save(
        &self,
        py: Python<'_>,
        e: u64,
        attr: &str,
        v: &Bound<'_, pyo3::types::PyAny>,
        t: u64,
    ) -> PyResult<()> {
        let value = py_to_value(v)?;
        py.allow_threads(|| self.inner.save(e, attr, value, t))
            .map_err(to_string_err)
    }

    #[pyo3(signature = (e, attr, v, t))]
    fn retract(
        &self,
        py: Python<'_>,
        e: u64,
        attr: &str,
        v: &Bound<'_, pyo3::types::PyAny>,
        t: u64,
    ) -> PyResult<()> {
        let value = py_to_value(v)?;
        py.allow_threads(|| self.inner.retract(e, attr, value, t))
            .map_err(to_string_err)
    }

    fn allocate_entity_id(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_entity_id())
            .map_err(to_string_err)
    }

    fn allocate_tx(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_tx())
            .map_err(to_string_err)
    }

    fn allocate_in_partition(&self, py: Python<'_>, partition_id: u64) -> PyResult<u64> {
        py.allow_threads(|| self.inner.allocate_in_partition(partition_id))
            .map_err(to_string_err)
    }

    fn is_unique(&self, py: Python<'_>, aid: u32) -> PyResult<bool> {
        py.allow_threads(|| self.inner.is_unique(aid))
            .map_err(to_string_err)
    }

    fn default_user_partition(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.default_user_partition())
            .map_err(to_string_err)
    }

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

    fn memtable_count(&self, py: Python<'_>, cf: u32) -> PyResult<u64> {
        py.allow_threads(|| self.inner.memtable_count(cf))
            .map_err(to_string_err)
    }

    fn journal_size(&self, py: Python<'_>) -> PyResult<u64> {
        py.allow_threads(|| self.inner.journal_size())
            .map_err(to_string_err)
    }

    fn cf_stats(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.cf_stats(cf))
            .map_err(to_string_err)
    }

    fn db_stats(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.db_stats())
            .map_err(to_string_err)
    }

    fn gc_full(&self, py: Python<'_>, dry_run: bool, nowait: bool) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.gc_full(dry_run, nowait))
            .map_err(to_string_err)
    }

    fn internal_status(&self, py: Python<'_>, target: &str) -> PyResult<String> {
        py.allow_threads(|| self.inner.internal_status(target))
            .map_err(to_string_err)
    }

    // ── KV-level operations (for raw storage tests) ──

    fn put(&self, py: Python<'_>, cf: u32, key: Vec<u8>) -> PyResult<()> {
        py.allow_threads(|| self.inner.kv_put(cf, &key))
            .map_err(to_string_err)
    }

    fn get(&self, py: Python<'_>, cf: u32, key: Vec<u8>) -> PyResult<bool> {
        py.allow_threads(|| self.inner.kv_get(cf, &key))
            .map_err(to_string_err)
    }

    fn scan(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.kv_scan(cf, &prefix))
            .map_err(to_string_err)
    }

    fn batch_write(&self, py: Python<'_>, ops: Vec<u8>) -> PyResult<()> {
        py.allow_threads(|| self.inner.kv_batch_write(&ops))
            .map_err(to_string_err)
    }

    fn batch_put(&self, py: Python<'_>, cf: u32, keys: Vec<u8>) -> PyResult<()> {
        py.allow_threads(|| self.inner.kv_batch_put(cf, &keys))
            .map_err(to_string_err)
    }

    fn items(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.kv_items(cf))
            .map_err(to_string_err)
    }

    fn scan_reverse(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.kv_scan_reverse(cf, &prefix))
            .map_err(to_string_err)
    }

    fn open_cursor_direct(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<PyCursorHandle> {
        let handle = py.allow_threads(|| self.inner.kv_open_cursor_direct(cf, &prefix))
            .map_err(to_string_err)?;
        Ok(PyCursorHandle { inner: handle })
    }

    fn open_cursor_reverse_direct(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<PyCursorHandle> {
        let handle = py.allow_threads(|| self.inner.kv_open_cursor_reverse_direct(cf, &prefix))
            .map_err(to_string_err)?;
        Ok(PyCursorHandle { inner: handle })
    }

    fn cursor_current_key(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) -> PyResult<(bool, Vec<Vec<u8>>)> {
        let mut buf = Vec::new();
        let has = cursor.borrow().inner.cursor.borrow().is_valid();
        if has {
            if let Some(k) = cursor.borrow().inner.cursor.borrow().current_key() {
                buf.push(k.to_vec());
            }
        }
        Ok((has, buf))
    }

    fn cursor_step(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) {
        cursor.borrow().inner.cursor.borrow_mut().step();
    }

    fn cursor_seek(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, target: Vec<u8>) {
        cursor.borrow().inner.cursor.borrow_mut().seek(&target);
    }

    fn cursor_skip_group(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, group_end: u32) {
        cursor.borrow().inner.cursor.borrow_mut().skip_group(group_end as usize);
    }

    fn cursor_update_end(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, end: Vec<u8>) {
        cursor.borrow().inner.cursor.borrow_mut().update_end(&end);
    }

    fn journal_put(&self, py: Python<'_>, key: Vec<u8>, value: Vec<u8>) -> PyResult<()> {
        py.allow_threads(|| self.inner.journal_append(&key, &value))
            .map_err(to_string_err)
    }

    fn journal_scan(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        py.allow_threads(|| self.inner.journal_read())
            .map_err(to_string_err)
    }

    fn approximate_sizes(&self, py: Python<'_>, cf: u32, start: Vec<u8>, end: Vec<u8>) -> PyResult<u64> {
        py.allow_threads(|| {
            let packed = self.inner.kv_scan(cf, &start)?;
            let mut count = 0u64;
            let mut pos = 0;
            while pos + 4 <= packed.len() {
                let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
                pos += 4 + klen;
                count += 1;
            }
            Ok(count.max(1))
        }).map_err(to_string_err)
    }

    fn compile_scheme(&self, py: Python<'_>, scheme_text: &str) -> PyResult<PyProgramHandle> {
        let handle = py.allow_threads(|| self.inner.compile_scheme(scheme_text))
            .map_err(to_string_err)?;
        Ok(PyProgramHandle { inner: handle })
    }

    fn compile_scheme_dml(&self, py: Python<'_>, scheme_text: &str) -> PyResult<PyProgramHandle> {
        let handle = py.allow_threads(|| self.inner.compile_scheme_dml(scheme_text))
            .map_err(to_string_err)?;
        Ok(PyProgramHandle { inner: handle })
    }

    fn compile_scheme_debug(&self, py: Python<'_>, scheme_text: &str) -> PyResult<Vec<Vec<u8>>> {
        let rows = py.allow_threads(|| self.inner.compile_scheme_debug(scheme_text))
            .map_err(to_string_err)?;
        Ok(rows.iter().map(|row| {
            let mut buf = Vec::new();
            for val in row {
                spier_value::query_codec::encode_one(&mut buf, val);
            }
            buf
        }).collect())
    }
}

// ── PyJournal — wraps NimKVStore journal operations ──

#[pyclass(name = "Journal", unsendable)]
pub struct PyJournal {
    inner: Mutex<Option<spier_page_store_nim::NimKVStore>>,
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
        let inner = py.allow_threads(|| spier_page_store_nim::NimKVStore::open(&cfg))
            .map_err(to_string_err)?;
        Ok(Self { inner: Mutex::new(Some(inner)) })
    }

    #[pyo3(signature = (key, value))]
    fn journal_append(&self, py: Python<'_>, key: Vec<u8>, value: Vec<u8>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("journal closed")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_append(&key, &value))
            .map_err(to_string_err)
    }

    fn journal_read(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("journal closed")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_read())
            .map_err(to_string_err)
    }

    fn journal_truncate(&self, py: Python<'_>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("journal closed")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_truncate())
            .map_err(to_string_err)
    }

    fn close(&self) {
        self.inner.lock().unwrap().take();
    }
}

// ── PyKVStore — raw KV store without transactor/bootstrap ──

#[pyclass(name = "KVStore", unsendable)]
pub struct PyKVStore {
    inner: Mutex<Option<spier_page_store_nim::NimKVStore>>,
}

#[pymethods]
impl PyKVStore {
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
        let inner = py.allow_threads(|| spier_page_store_nim::NimKVStore::open(&cfg))
            .map_err(to_string_err)?;
        Ok(Self { inner: Mutex::new(Some(inner)) })
    }

    fn put(&self, py: Python<'_>, cf: u32, key: Vec<u8>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.put(cf, &key)).map_err(to_string_err)
    }

    fn get(&self, py: Python<'_>, cf: u32, key: Vec<u8>) -> PyResult<bool> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.get(cf, &key)).map_err(to_string_err)
    }

    fn scan(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<Vec<u8>> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.scan(cf, &prefix)).map_err(to_string_err)
    }

    fn flush(&self, py: Python<'_>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.flush()).map_err(to_string_err)
    }

    fn items(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.scan(cf, b"")).map_err(to_string_err)
    }

    fn batch_write(&self, py: Python<'_>, ops: Vec<u8>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.batch_write(&ops)).map_err(to_string_err)
    }

    fn batch_put(&self, py: Python<'_>, cf: u32, keys: Vec<u8>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.batch_put(cf, &keys)).map_err(to_string_err)
    }

    fn scan_reverse(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<Vec<u8>> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.scan_reverse(cf, &prefix)).map_err(to_string_err)
    }

    fn journal_put(&self, py: Python<'_>, key: Vec<u8>, value: Vec<u8>) -> PyResult<()> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_append(&key, &value)).map_err(to_string_err)
    }

    fn journal_scan(&self, py: Python<'_>) -> PyResult<Vec<u8>> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_read()).map_err(to_string_err)
    }

    fn open_cursor_direct(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<PyCursorHandle> {
        self.open_cursor_impl(py, cf, prefix, false)
    }

    fn open_cursor_reverse_direct(&self, py: Python<'_>, cf: u32, prefix: Vec<u8>) -> PyResult<PyCursorHandle> {
        self.open_cursor_impl(py, cf, prefix, true)
    }

    fn open_cursor_impl(&self, _py: Python<'_>, cf: u32, prefix: Vec<u8>, reverse: bool) -> PyResult<PyCursorHandle> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        let packed = if reverse {
            inner.scan_reverse(cf, &prefix).map_err(to_string_err)?
        } else {
            inner.scan(cf, &prefix).map_err(to_string_err)?
        };
        let mut keys: Vec<Vec<u8>> = Vec::new();
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4;
            if pos + klen > packed.len() { break; }
            keys.push(packed[pos..pos + klen].to_vec());
            pos += klen;
        }
        let valid = !keys.is_empty();
        let cursor = spier_page_store_nim::storage_traits::CursorHandle {
            cursor: std::sync::Arc::new(std::cell::RefCell::new(ReverseCursor { keys, idx: 0, valid })),
        };
        Ok(PyCursorHandle { inner: cursor })
    }

    fn cursor_current_key(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) -> PyResult<(bool, Vec<Vec<u8>>)> {
        let mut buf = Vec::new();
        let has = cursor.borrow().inner.cursor.borrow().is_valid();
        if has {
            if let Some(k) = cursor.borrow().inner.cursor.borrow().current_key() {
                buf.push(k.to_vec());
            }
        }
        Ok((has, buf))
    }

    fn cursor_step(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>) {
        cursor.borrow().inner.cursor.borrow_mut().step();
    }

    fn cursor_seek(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, target: Vec<u8>) {
        cursor.borrow().inner.cursor.borrow_mut().seek(&target);
    }

    fn cursor_skip_group(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, group_end: u32) {
        cursor.borrow().inner.cursor.borrow_mut().skip_group(group_end as usize);
    }

    fn cursor_update_end(&self, _py: Python<'_>, cursor: &Bound<'_, PyCursorHandle>, end: Vec<u8>) {
        cursor.borrow().inner.cursor.borrow_mut().update_end(&end);
    }

    fn close(&self) {
        self.inner.lock().unwrap().take();
    }

    fn path(&self) -> String { String::from("") }

    fn memtable_size(&self, py: Python<'_>) -> PyResult<u64> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.memtable_size()).map_err(to_string_err)
    }

    fn memtable_count(&self, py: Python<'_>, cf: u32) -> PyResult<u64> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        let packed = py.allow_threads(|| inner.scan(cf, b"")).map_err(to_string_err)?;
        let mut count = 0u64;
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4 + klen;
            count += 1;
        }
        Ok(count)
    }

    fn journal_size(&self, py: Python<'_>) -> PyResult<u64> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        py.allow_threads(|| inner.journal_read().map(|d| d.len() as u64)).map_err(to_string_err)
    }

    fn approximate_sizes(&self, py: Python<'_>, cf: u32, start: Vec<u8>, _end: Vec<u8>) -> PyResult<u64> {
        let guard = self.inner.lock().unwrap();
        let inner = guard.as_ref().ok_or("not open")
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e))?;
        let packed = py.allow_threads(|| inner.scan(cf, &start)).map_err(to_string_err)?;
        let mut count = 0u64;
        let mut pos = 0;
        while pos + 4 <= packed.len() {
            let klen = u32::from_be_bytes([packed[pos], packed[pos+1], packed[pos+2], packed[pos+3]]) as usize;
            pos += 4 + klen;
            count += 1;
        }
        Ok(count.max(1))
    }

    fn cf_stats(&self, py: Python<'_>, cf: u32) -> PyResult<Vec<u8>> {
        let count = self.memtable_count(py, cf).unwrap_or(0);
        let mut buf = Vec::new();
        let name = b"eavt";
        buf.extend_from_slice(&(name.len() as u16).to_le_bytes());
        buf.extend_from_slice(name);
        buf.extend_from_slice(&0u64.to_le_bytes()); buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes()); buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&count.to_le_bytes());
        Ok(buf)
    }

    fn db_stats(&self, _py: Python<'_>) -> PyResult<Vec<u8>> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        Ok(buf)
    }

    #[pyo3(signature = (dry_run, nowait))]
    fn gc_full(&self, _py: Python<'_>, dry_run: bool, nowait: bool) -> PyResult<Vec<u8>> {
        let mut buf = Vec::with_capacity(41);
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        buf.push(if dry_run { 1u8 } else { 0u8 });
        Ok(buf)
    }

}

#[pymodule]
fn spier_eavt_query_py(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyEngine>()?;
    m.add_class::<PyProgramHandle>()?;
    m.add_class::<PySessionHandle>()?;
    m.add_class::<PyCursorHandle>()?;
    m.add_class::<PyJournal>()?;
    m.add_class::<PyKVStore>()?;
    Ok(())
}

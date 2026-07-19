use std::cell::RefCell;
use std::sync::Arc;

use spier_storage_traits::Cursor;
use spier_transactor::keys::{
    decode_fixed, decode_float64, decode_int64, decode_suffix, decode_variable,
    decode_variable_unordered, encode_fixed, encode_int64, encode_suffix, encode_variable,
    encode_variable_unordered,
};
use spier_transactor::resolver_consts::{
    DB_TYPE_BLOB, DB_TYPE_BOOLEAN, DB_TYPE_BYTES, DB_TYPE_FLOAT, DB_TYPE_INSTANT,
    DB_TYPE_STRING,
};
use spier_value::{Value, TAG_BYTES, TAG_INT64, TAG_STR};

pub struct InvalidCursor;

impl spier_storage_traits::Cursor for InvalidCursor {
    fn is_valid(&self) -> bool {
        false
    }
    fn current_key(&self) -> Option<&[u8]> {
        None
    }
    fn step(&mut self) {}
    fn skip_group(&mut self, _group_end: usize) {}
    fn seek(&mut self, _target: &[u8]) {}
    fn update_end(&mut self, _end: &[u8]) {}
    fn invalidate(&mut self) {}
}

// ---------------------------------------------------------------------------
// PositionStack — encapsulates the per-position cursor state.
//
// Fixed entries are pushed by `scanner-push` and popped by `scanner-pop`.
// `advance` finds the next active value at a position, constrained to the
// prefix of the current Fixed entries.
// ---------------------------------------------------------------------------

/// Entrada da pilha de posições. Todas as posições empilhadas são *fixas*
/// (bound values) — a iteração de cada nível varrido é controlada pelo
// compilador via `advance_to_active_at` / `leap_next_at`, sem entries
// `Scanned`. A posição de cada entrada é o seu índice no vetor `stack`
// (== posição em `idx_order`).
pub enum StackEntry {
    Fixed(Value),
}

pub struct PositionStack {
    cursor: Arc<RefCell<dyn Cursor>>,
    idx_order: Vec<String>,
    // pilha única de entradas — push ao entrar, pop ao sair.
    // a posição de uma entrada é o seu índice neste vetor (= posição em idx_order).
    stack: Vec<StackEntry>,
    // chave ativa atual (linha do grupo corrente)
    current_active_key: Option<Vec<u8>>,
    at_end: bool,
}

impl PositionStack {
    pub fn new(cursor: Arc<RefCell<dyn Cursor>>, idx_order: Vec<String>) -> Self {
        Self {
            cursor,
            idx_order,
            stack: Vec::new(),
            current_active_key: None,
            at_end: true,
        }
    }

    pub fn open_cursor(&mut self, cursor: Arc<RefCell<dyn Cursor>>) {
        self.cursor = cursor;
        self.at_end = false;
    }

    pub fn cursor(&self) -> &Arc<RefCell<dyn Cursor>> {
        &self.cursor
    }

    pub fn idx_order(&self) -> &[String] {
        &self.idx_order
    }

    // -- pilha única (agnóstica ao tipo) --

    /// Empilha uma posição *fixa* com o valor exato.
    pub fn push_fixed(&mut self, val: &Value) {
        self.stack.push(StackEntry::Fixed(val.clone()));
    }

    /// Remove e devolve o valor do topo da pilha.
    pub fn pop_fixed(&mut self) -> Option<Value> {
        self.stack.pop().map(|e| match e {
            StackEntry::Fixed(v) => v,
        })
    }

    /// Entradas fixas com sua posição (índice no vetor == posição em `idx_order`),
    /// em ordem crescente — para rebuild do prefixo de busca.
    pub fn fixed_entries(&self) -> Vec<(usize, Value)> {
        let n = self.idx_order.len();
        self.stack
            .iter()
            .enumerate()
            .filter_map(|(i, e)| match e {
                StackEntry::Fixed(v) => {
                    assert!(
                        i < n,
                        "fixed entry at stack index {i} exceeds idx_order length {n}; \
                         position stack desyncronizada (fixos devem ser empilhados em ordem crescente de idx_order)"
                    );
                    Some((i, v.clone()))
                }
            })
            .collect()
    }

    // -- estado ativo --

    pub fn current_active_key(&self) -> Option<&[u8]> {
        self.current_active_key.as_deref()
    }

    pub fn set_active_key(&mut self, key: Option<Vec<u8>>) {
        self.current_active_key = key;
    }

    pub fn at_end(&self) -> bool {
        self.at_end
    }

    pub fn set_at_end(&mut self, v: bool) {
        self.at_end = v;
    }

    /// Posição corrente para iteração = próximo slot livre da pilha
    /// (stack.len()). Toda entrada na pilha vem de scanner-push (Fixed), e
    /// scanner-iterate itera no nível imediatamente após o último Fixed
    /// empilhado — i.e., o primeiro slot de `idx_order` ainda sem Fixed.
    pub fn current_position(&self) -> usize {
        self.stack.len()
    }
}

pub fn encode_bound_value(val: &Value) -> Vec<u8> {
    match val {
        Value::Text(_) | Value::Bytes(_) => encode_variable(val),
        _ => encode_fixed(val),
    }
}

fn find_v_end(key: &[u8], start: usize, is_unordered: bool) -> usize {
    if is_unordered {
        if start + 4 > key.len() {
            return key.len();
        }
        let len = u32::from_be_bytes(key[start..start + 4].try_into().unwrap()) as usize;
        return start + 4 + len;
    }
    let mut pos = start;
    while pos + 9 <= key.len() {
        let ctrl = key[pos + 8];
        if ctrl == 0xFF {
            pos += 9;
        } else {
            return pos + 9;
        }
    }
    key.len()
}

fn is_unordered_attr(vt: Option<u32>) -> bool {
    vt == Some(DB_TYPE_BLOB)
}

// ---------------------------------------------------------------------------
// V2Scanner — scanner-centric triejoin: one scanner per clause, position-aware
// ---------------------------------------------------------------------------

/// Resultado da comparação de uma chave contra o prefixo fixo corrente do
/// scanner. Os callers decidem como reagir a cada caso (seek, abort, aceitar).
#[derive(Clone, Copy, PartialEq, Eq)]
enum KeyVsPrefix {
    /// Scanner sem entradas Fixed — qualquer chave é aceitável.
    NoPrefix,
    /// Chave estritamente anterior à faixa do prefixo (cursor pode seek-to-prefix).
    Before,
    /// Chave começa com o prefixo (está dentro da faixa).
    Match,
    /// Chave estritamente posterior à faixa do prefixo (faixa esgotada).
    After,
}

pub struct V2Scanner {
    pos: PositionStack,
    index_name: String,
    as_of_tx: Option<u64>,
    value_attr_type: Option<u32>,
    history_mode: bool,
    prefix_cache: Vec<u8>,
    /// True quando a posição "t" está entre as Fixed empilhadas. Nesse caso,
    /// o LSB do último byte do prefixo carrega o bit 'added' (em vez de um
    /// bit significativo de t) e o comparador deve ignorá-lo para casar
    /// ambas as variantes (retracted=true/false) do mesmo t.
    t_in_prefix: bool,
}


// V2Scanner is single-threaded but must be Send to be wrapped in
// Arc<Mutex<V2Scanner>> for the opaque resource SExpr variant.
unsafe impl Send for V2Scanner {}

impl V2Scanner {
    pub fn new(
        index_name: &str,
        idx_order: Vec<String>,
        as_of_tx: Option<u64>,
        value_attr_type: Option<u32>,
    ) -> Self {
        Self {
            pos: PositionStack::new(Arc::new(RefCell::new(InvalidCursor)), idx_order),
            index_name: index_name.to_ascii_uppercase(),
            as_of_tx,
            value_attr_type,
            history_mode: false,
            prefix_cache: Vec::new(),
            t_in_prefix: false,
        }
    }

    pub fn set_history_mode(&mut self) {
        self.history_mode = true;
    }

    /// Prefixo codificado corrente (debug-only: exposto ao Scheme evaluator
    /// via host fn `scanner-prefix`). Lê direto de `prefix_cache`; callers
    /// internos devem preferir `classify_key` em vez de inspecionar os bytes.
    pub(crate) fn prefix_bytes(&self) -> &[u8] {
        &self.prefix_cache
    }

    /// Compara `key` contra o prefixo fixo corrente. Caso degenerado
    /// (`prefix_cache` vazio) devolve `NoPrefix`; callers tratam cada
    /// variante como preferirem (seek / set_at_end / aceitar). Lida com
    /// chaves mais curtas que o prefixo: nesse cenário a chave ordena
    /// lexicograficamente antes do prefixo, então devolve `Before`.
    fn classify_key(&self, key: &[u8]) -> KeyVsPrefix {
        let bp = &self.prefix_cache;
        if bp.is_empty() {
            return KeyVsPrefix::NoPrefix;
        }
        let n = bp.len().min(key.len());
        let ord = if self.t_in_prefix {
            // LSB do último byte carrega o bit 'added' — ignorar para casar
            // ambas as variantes (retracted=true/false) do mesmo t.
            let last = n - 1;
            match key[..last].cmp(&bp[..last]) {
                std::cmp::Ordering::Equal => (key[last] & 0xFE).cmp(&(bp[last] & 0xFE)),
                other => other,
            }
        } else {
            key[..n].cmp(&bp[..n])
        };
        match ord {
            std::cmp::Ordering::Less => KeyVsPrefix::Before,
            std::cmp::Ordering::Greater => KeyVsPrefix::After,
            std::cmp::Ordering::Equal => {
                if key.len() < bp.len() {
                    KeyVsPrefix::Before
                } else {
                    KeyVsPrefix::Match
                }
            }
        }
    }

    pub fn save_value(&mut self, val: &Value) {
        self.pos.push_fixed(val);
        self.recompute_prefix();
    }

    pub fn pop_saved_value(&mut self) {
        self.pos.pop_fixed();
        self.recompute_prefix();
    }

    /// Recalcula `prefix_cache` a partir das Fixed entries empilhadas e do
    /// `value_attr_type` atual. Deve ser chamado após qualquer mutação que
    /// afete o resultado do encode (push/pop da pilha ou troca do tipo).
    fn recompute_prefix(&mut self) {
        let fixed = self.pos.fixed_entries();
        let mut buf = Vec::new();
        let mut t_in_prefix = false;
        for (pos_idx, pos_name) in self.pos.idx_order().iter().enumerate() {
            let pv = match fixed.iter().find(|(idx, _)| *idx == pos_idx) {
                Some((_, v)) => v,
                None => break,
            };
            match pos_name.as_str() {
                "a" => buf.extend_from_slice(&(pv.raw_int() as u32).to_be_bytes()),
                "e" => buf.extend_from_slice(&encode_int64(pv.raw_int()).to_be_bytes()),
                "v" => {
                    if self.value_attr_type == Some(DB_TYPE_BLOB) {
                        buf.extend_from_slice(&encode_variable_unordered(pv));
                    } else if matches!(pv, Value::Text(_) | Value::Bytes(_)) {
                        buf.extend_from_slice(&encode_variable(pv));
                    } else {
                        buf.extend_from_slice(&encode_fixed(pv));
                    }
                }
                "t" => {
                    let suffix = encode_suffix(pv.raw_int() as u64, false);
                    buf.extend_from_slice(&suffix.to_be_bytes());
                    t_in_prefix = true;
                }
                _ => {
                    let enc = encode_bound_value(pv);
                    buf.extend_from_slice(&enc);
                }
            }
        }
        self.prefix_cache = buf;
        self.t_in_prefix = t_in_prefix;
    }

    pub fn attr_id_from_prefix_bytes(&self) -> Option<u32> {
        let off = match self.index_name.as_str() {
            "EAVT" | "VAET" => 8usize,
            "AEVT" | "AVET" => 0usize,
            _ => return None,
        };
        let key = &self.prefix_cache;
        if key.len() >= off + 4 {
            Some(u32::from_be_bytes(key[off..off + 4].try_into().ok()?))
        } else {
            None
        }
    }

    pub fn attr_id_from_key(&self) -> Option<u32> {
        let key = self.pos.current_active_key()?;
        let idx = &self.index_name;
        let off = match idx.as_str() {
            "EAVT" | "VAET" => 8usize,
            "AEVT" | "AVET" => 0usize,
            _ => 8,
        };
        if key.len() >= off + 4 {
            Some(u32::from_be_bytes(key[off..off + 4].try_into().ok()?))
        } else {
            None
        }
    }

    pub fn value_attr_type(&self) -> Option<u32> {
        self.value_attr_type
    }

    pub fn set_value_attr_type(&mut self, vt: Option<u32>) {
        self.value_attr_type = vt;
        self.recompute_prefix();
    }

    pub fn current_position(&self) -> usize {
        self.pos.current_position()
    }

    pub fn set_cursor(&mut self, cursor: Arc<RefCell<dyn Cursor>>) {
        self.pos.open_cursor(cursor);
    }

    pub fn at_end(&self) -> bool {
        self.pos.at_end()
    }

    /// Nome da coluna na posição corrente (topo da pilha) de `idx_order`
    /// ("e"/"a"/"v"/"t"/"added"). A posição é derivada do topo da pilha:
    /// posições `[0, idx_order.len())` mapeiam para os nomes de `idx_order`;
    /// posições `len` e `len+1` são "t" e "added". Fora disso é estado
    /// inválido e provoca pânico com mensagem clara.
    fn pos_name(&self) -> &str {
        let pos_idx = self.current_position();
        assert!(
            pos_idx < self.pos.idx_order().len() + 2,
            "posição {pos_idx} fora da faixa válida [0, {}] de idx_order {:?}",
            self.pos.idx_order().len() + 1,
            self.pos.idx_order()
        );
        if pos_idx >= self.pos.idx_order().len() {
            return "t";
        }
        self.pos
            .idx_order()
            .get(pos_idx)
            .map(|s| s.as_str())
            .unwrap_or("v")
    }

    fn is_variable_value(&self, key_len: usize) -> bool {
        if matches!(
            self.value_attr_type,
            Some(DB_TYPE_STRING) | Some(DB_TYPE_BYTES) | Some(DB_TYPE_BLOB)
        ) {
            return true;
        }
        key_len != 28
    }

    fn is_unordered(&self) -> bool {
        is_unordered_attr(self.value_attr_type)
    }

    /// Offset de início do valor na posição corrente dentro de `key`. Posições
    /// além de `idx_order` (t/added) caem no sufixo (últimos 8 bytes).
    fn value_start(&self, key: &[u8]) -> usize {
        let pos_idx = self.current_position();
        let pos_name = self.pos_name();
        if pos_idx >= self.pos.idx_order().len() || pos_name == "t" || pos_name == "added" {
            return key.len() - 8;
        }
        match self.index_name.as_str() {
            "EAVT" => match pos_idx {
                0 => 0,
                1 => 8,
                _ => 12,
            },
            "AEVT" => match pos_idx {
                0 => 0,
                1 => 4,
                _ => 12,
            },
            "AVET" => match pos_idx {
                0 => 0,
                1 => 4,
                _ => {
                    let vs = 4usize;
                    if self.is_variable_value(key.len()) {
                        find_v_end(key, vs, self.is_unordered())
                    } else {
                        vs + 8
                    }
                }
            },
            "VAET" => match pos_idx {
                0 => 0,
                1 => 8,
                _ => 12,
            },
            _ => 12,
        }
    }

    fn value_end(&self, key: &[u8]) -> usize {
        let pos_idx = self.current_position();
        if pos_idx >= self.pos.idx_order().len() {
            return key.len();
        }
        let pos_name = self.pos_name();
        let start = self.value_start(key);
        match pos_name {
            "e" => start + 8,
            "a" => start + 4,
            "v" => {
                if self.is_variable_value(key.len()) {
                    find_v_end(key, start, self.is_unordered())
                } else {
                    start + 8
                }
            }
            _ => key.len(),
        }
    }

    fn extract_raw(&self, key: &[u8]) -> Extracted {
        let pos_name = self.pos_name();
        let pos_idx = self.current_position();
        if pos_idx >= self.pos.idx_order().len() || pos_name == "t" || pos_name == "added" {
            let suffix = Self::extract_suffix(key);
            let (t, retracted) = decode_suffix(suffix);
            return if pos_name == "added" {
                Extracted::Int(if retracted { 0 } else { 1 })
            } else {
                Extracted::Int(t)
            };
        }
        let start = self.value_start(key);
        let end = self.value_end(key);
        match pos_name {
            "a" => {
                Extracted::Int(u32::from_be_bytes(key[start..start + 4].try_into().unwrap()) as u64)
            }
            "e" => Extracted::Int(u64::from_be_bytes(
                key[start..start + 8].try_into().unwrap(),
            )),
            _ => {
                if self.is_variable_value(key.len()) {
                    Extracted::Bytes(key[start..end].to_vec())
                } else {
                    Extracted::Int(u64::from_be_bytes(
                        key[start..start + 8].try_into().unwrap(),
                    ))
                }
            }
        }
    }

    /// Extrai o valor na posição corrente (topo da pilha).
    pub fn extract_current(&self) -> Option<Value> {
        let key = self.pos.current_active_key()?;
        if !matches!(self.classify_key(key), KeyVsPrefix::Match | KeyVsPrefix::NoPrefix) {
            return None;
        }
        let raw = self.extract_raw(key);
        let pos_name = self.pos_name();
        Some(match pos_name {
            "e" => {
                if let Extracted::Int(n) = raw {
                    Value::Int64(decode_int64(n))
                } else {
                    Value::Int64(0)
                }
            }
            "a" => {
                if let Extracted::Int(n) = raw {
                    Value::Int64(n as i64)
                } else {
                    Value::Int64(0)
                }
            }
            "t" => {
                if let Extracted::Int(n) = raw {
                    Value::Int64(n as i64)
                } else {
                    Value::Int64(0)
                }
            }
            "added" => {
                if let Extracted::Int(n) = raw {
                    Value::Bool(n as u8)
                } else {
                    Value::Bool(0)
                }
            }
            _ => self.decode_v(&raw, key),
        })
    }

    fn decode_v(&self, raw: &Extracted, key: &[u8]) -> Value {
        if self.is_variable_value(key.len()) {
            if let Extracted::Bytes(b) = raw {
                match self.value_attr_type {
                    Some(DB_TYPE_BYTES) => decode_variable(TAG_BYTES, b),
                    Some(DB_TYPE_BLOB) => decode_variable_unordered(b),
                    _ => decode_variable(TAG_STR, b),
                }
            } else {
                Value::Int64(0)
            }
        } else if let Extracted::Int(n) = raw {
            // REF unificado com LONG: ambos aplicam sign-flip no decode.
            match self.value_attr_type {
                Some(DB_TYPE_FLOAT) => Value::Float64(decode_float64(*n)),
                Some(DB_TYPE_BOOLEAN) => Value::Bool(*n as u8),
                Some(DB_TYPE_INSTANT) => Value::Timestamp(decode_int64(*n)),
                _ => decode_fixed(TAG_INT64, *n),
            }
        } else {
            Value::Int64(0)
        }
    }

    fn extract_suffix(key: &[u8]) -> u64 {
        let start = key.len() - 8;
        u64::from_be_bytes(key[start..start + 8].try_into().unwrap())
    }

    pub fn advance_to_active_at(&mut self) {
        let t0 = if crate::engine::opcodes::debug_timing_enabled() {
            Some(std::time::Instant::now())
        } else {
            None
        };
        self.advance_to_active_at_inner();
        if let Some(t0) = t0 {
            crate::engine::opcodes::scanner_advance_elapsed(t0.elapsed().as_nanos() as u64);
        }
    }

    fn advance_to_active_at_inner(&mut self) {
        let pos_name = self.pos_name();

        if pos_name == "added" {
            if self.pos.current_active_key().is_some() {
                self.pos.set_at_end(false);
            } else {
                self.pos.set_at_end(true);
            }
            return;
        }

        let as_of_tx = self.as_of_tx;
        let is_t_pos = pos_name == "t";

        if self.history_mode && is_t_pos {
            self.advance_history_each();
            return;
        }

        while self.pos.cursor().borrow().is_valid() {
            let first_key = self.pos.cursor().borrow().current_key().unwrap().to_vec();
            if first_key.len() < 8 {
                self.pos.cursor().borrow_mut().step();
                continue;
            }
            match self.classify_key(&first_key) {
                KeyVsPrefix::NoPrefix | KeyVsPrefix::Match => {}
                KeyVsPrefix::Before => {
                    // Cursor antes da faixa do prefixo — pula direto pra ela.
                    self.pos.cursor().borrow_mut().seek(&self.prefix_cache);
                    continue;
                }
                KeyVsPrefix::After => {
                    // Passou do fim da faixa — sem mais resultados.
                    self.pos.set_at_end(true);
                    return;
                }
            }
            let first_raw = self.extract_raw(&first_key);
            let group_end = first_key.len() - 8;
            let mut cur_group = first_key[..group_end].to_vec();
            let mut found_key: Option<Vec<u8>> = None;

            while self.pos.cursor().borrow().is_valid() {
                let key = self.pos.cursor().borrow().current_key().unwrap().to_vec();
                if key.len() < 8 {
                    self.pos.cursor().borrow_mut().step();
                    continue;
                }
                let ge = key.len() - 8;
                if key[..ge] != cur_group[..] {
                    if found_key.is_some() {
                        break;
                    }
                    cur_group = key[..ge].to_vec();
                }

                let raw = self.extract_raw(&key);
                if raw != first_raw {
                    break;
                }

                let suffix = Self::extract_suffix(&key);
                let (t, retracted) = decode_suffix(suffix);

                if as_of_tx.is_some() && t > as_of_tx.unwrap() {
                    self.pos.cursor().borrow_mut().step();
                    continue;
                }

                if self.history_mode || !retracted {
                    found_key = Some(key.clone());
                }

                if found_key.is_some() {
                    break;
                }
                // No non-retracted key found in this group — skip to next.
                crate::engine::opcodes::skip_group_call();
                self.pos.cursor().borrow_mut().skip_group(ge);
            }

            if let Some(bk) = found_key {
                self.pos.set_active_key(Some(bk.clone()));
                self.pos.set_at_end(false);
                return;
            }
        }
        self.pos.set_active_key(None);
        self.pos.set_at_end(true);
    }

    fn advance_history_each(&mut self) {
        let as_of_tx = self.as_of_tx;

        while self.pos.cursor().borrow().is_valid() {
            let key = self.pos.cursor().borrow().current_key().unwrap().to_vec();
            if key.len() < 8 {
                self.pos.cursor().borrow_mut().step();
                continue;
            }
            // history_mode itera monoticamente — qualquer divergência do
            // prefixo (antes ou depois) encerra a iteração, sem seek-forward.
            match self.classify_key(&key) {
                KeyVsPrefix::NoPrefix | KeyVsPrefix::Match => {}
                KeyVsPrefix::Before | KeyVsPrefix::After => {
                    self.pos.set_at_end(true);
                    return;
                }
            }

            let suffix = Self::extract_suffix(&key);
            let (t, _) = decode_suffix(suffix);

            if as_of_tx.is_some() && t > as_of_tx.unwrap() {
                self.pos.cursor().borrow_mut().step();
                continue;
            }

            self.pos.set_active_key(Some(key));
            self.pos.set_at_end(false);
            return;
        }
        self.pos.set_active_key(None);
        self.pos.set_at_end(true);
    }

    pub fn leap_next_at(&mut self) {
        let pos_name = self.pos_name();
        if pos_name == "added" {
            self.pos.set_at_end(true);
            return;
        }
        if let Some(key) = self.pos.current_active_key().map(|k| k.to_vec()) {
            let raw = self.extract_raw(&key);
            self.seek_past_value_at(&raw);
        }
        self.advance_to_active_at();
    }

    fn seek_past_value_at(&mut self, current_raw: &Extracted) {
        let pos_name = self.pos_name();
        let key = match self.pos.current_active_key() {
            Some(k) => k.to_vec(),
            None => {
                self.pos.cursor().borrow_mut().invalidate();
                return;
            }
        };
        let vs = self.value_start(&key);

        let mut target = key[..vs].to_vec();

        if pos_name == "t" {
            let suffix = Self::extract_suffix(&key);
            if suffix == 0 {
                self.pos.cursor().borrow_mut().invalidate();
            } else {
                target.extend_from_slice(&(suffix + 1).to_be_bytes());
                self.pos.cursor().borrow_mut().seek(&target);
            }
            return;
        }

        let overflow = match current_raw {
            Extracted::Int(n) => {
                if pos_name == "a" {
                    let cur = *n as u32;
                    if cur == u32::MAX {
                        true
                    } else {
                        target.extend_from_slice(&(cur + 1).to_be_bytes());
                        false
                    }
                } else {
                    if *n == u64::MAX {
                        true
                    } else {
                        target.extend_from_slice(&(*n + 1).to_be_bytes());
                        false
                    }
                }
            }
            Extracted::Bytes(b) => {
                let mut inc = b.clone();
                let mut carry = true;
                for i in (0..inc.len()).rev() {
                    if carry {
                        if inc[i] < 0xFF {
                            inc[i] += 1;
                            carry = false;
                        } else {
                            inc[i] = 0;
                        }
                    }
                }
                if carry {
                    true
                } else {
                    target.extend_from_slice(&inc);
                    false
                }
            }
        };
        if overflow {
            self.pos.cursor().borrow_mut().invalidate();
        } else {
            self.pos.cursor().borrow_mut().seek(&target);
        }
    }

    pub fn seek_to_value(&mut self, value: &Value) {
        let t0 = if crate::engine::opcodes::debug_timing_enabled() {
            Some(std::time::Instant::now())
        } else {
            None
        };
        self.seek_to_value_inner(value);
        if let Some(t0) = t0 {
            crate::engine::opcodes::scanner_seek_elapsed(t0.elapsed().as_nanos() as u64);
        }
    }

    fn seek_to_value_inner(&mut self, value: &Value) {
        let pos_name = self.pos_name();
        let key = match self.pos.current_active_key() {
            Some(k) => k.to_vec(),
            None => {
                self.pos.cursor().borrow_mut().invalidate();
                return;
            }
        };
        let vs = self.value_start(&key);
        let mut target = key[..vs].to_vec();

        match pos_name {
            "e" => {
                target.extend_from_slice(&encode_int64(value.raw_int()).to_be_bytes());
            }
            "a" => {
                target.extend_from_slice(&(value.raw_int() as u32).to_be_bytes());
            }
            "v" => {
                if self.is_unordered() {
                    target.extend_from_slice(&encode_variable_unordered(value));
                } else if value.is_variable() {
                    target.extend_from_slice(&encode_variable(value));
                } else {
                    // LONG e REF unificados: ambos sign-flip via encode_fixed
                    target.extend_from_slice(&encode_fixed(value));
                }
            }
            _ => {}
        }
        target.extend_from_slice(&[0u8; 8]);
        self.pos.cursor().borrow_mut().seek(&target);
        self.advance_to_active_at();
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Extracted {
    Int(u64),
    Bytes(Vec<u8>),
}


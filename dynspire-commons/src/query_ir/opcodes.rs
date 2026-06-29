use std::collections::HashMap;
use std::sync::Arc;

use super::spec_kind::SpecKind;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpCode {
    Halt = 0,
    Goto = 1,
    Null = 10,
    Param = 14,
    ConstInt = 16,
    ConstStr = 17,
    ConstFloat = 18,
    ConstBool = 19,
    InternA = 21,
    AttrName = 51,
    ResolveVal = 52,
    CursorDeclare = 62,
    CursorBind = 63,
    CursorClose = 66,
    DepthOpen = 70,
    DepthUp = 71,
    LeapInit = 72,
    LeapNext = 73,
    BindGet = 80,
    BindSet = 81,
    RangeAdd = 91,
    RangeOp = 92,
    RangeBranch = 93,
    ResultRow = 100,
    EmitDeclare = 101,
    EmitValue = 102,
    EmitEnd = 103,
    ProbeDeclare = 110,
    ProbeBind = 111,
    ProbeBegin = 112,
    ProbeGetT = 113,
    ScanNext = 121,
    ExecInsert = 140,
    ExecAttribute = 141,
    ExecRetract = 143,
    LookupEntity = 144,
    AllocEntP = 145,
    DeclarePartition = 146,
    LoadTxEnt = 147,
    LookupValue = 149,
    // VM Bytecode v2 — scanner-centric triejoin
    ScannerOpen = 200,
    PrefixPush = 201,
    DepthEnter = 202,
    ScannerClose = 203,
}

// RangeOp op constants (RangeOp instruction p2 field)
pub const RANGE_OP_EQ: i32 = 0;
pub const RANGE_OP_NEQ: i32 = 1;
pub const RANGE_OP_GT: i32 = 2;
pub const RANGE_OP_GTE: i32 = 3;
pub const RANGE_OP_LT: i32 = 4;
pub const RANGE_OP_LTE: i32 = 5;
pub const RANGE_OP_IN: i32 = 6;

#[derive(Clone)]
pub struct Instruction {
    pub op: OpCode,
    pub p1: i32,
    pub p2: i32,
    pub p3: i32,
    pub p4: InstructionData,
}

#[derive(Clone)]
pub enum InstructionData {
    None,
    Int(i64),
    Float(f64),
    Str(String),
    CursorPlan(CursorPlanData),
    RangeFlags(i32),
}

impl Default for InstructionData {
    fn default() -> Self {
        Self::None
    }
}

#[derive(Clone)]
pub struct CursorPlanData {
    pub index_name: String,
    pub idx_order: [String; 5],
    pub specs: [SpecKind; 5],
    pub var_depths: Vec<(usize, String)>,
    pub same_var_constraints: HashMap<usize, Vec<String>>,
    pub active_depths: Vec<usize>,
    pub global_var_order: Vec<String>,
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn spec_kind_json(spec: &SpecKind) -> String {
    match spec {
        SpecKind::Var(name) => format!("{{\"kind\":\"var\",\"name\":\"{}\"}}", json_escape(name)),
        SpecKind::Bound(v) => format!("{{\"kind\":\"bound\",\"value\":{}}}", v),
        SpecKind::BoundAttr(aid) => format!("{{\"kind\":\"bound_attr\",\"aid\":{}}}", aid),
        SpecKind::BoundParam(idx) => format!("{{\"kind\":\"bound_param\",\"idx\":{}}}", idx),
        SpecKind::BoundValue(v) => {
            let val = match v {
                crate::value::Value::Int64(n) => format!("{}", n),
                crate::value::Value::Float64(f) => format!("{}", f),
                crate::value::Value::Text(s) => format!("\"{}\"", json_escape(s)),
                crate::value::Value::Bool(b) => format!("{}", *b != 0),
                other => format!("\"{}\"", json_escape(&format!("{:?}", other))),
            };
            format!("{{\"kind\":\"bound_value\",\"value\":{}}}", val)
        }
    }
}

fn instruction_data_json(data: &InstructionData) -> String {
    match data {
        InstructionData::None => "null".to_string(),
        InstructionData::Int(n) => format!("{}", n),
        InstructionData::Float(f) => format!("{}", f),
        InstructionData::Str(s) => format!("\"{}\"", json_escape(s)),
        InstructionData::RangeFlags(f) => format!("{}", f),
        InstructionData::CursorPlan(cp) => {
            let specs: Vec<String> = cp.specs.iter().map(spec_kind_json).collect();
            let var_depths: Vec<String> = cp.var_depths.iter()
                .map(|(d, n)| format!("[{},\"{}\"]", d, json_escape(n)))
                .collect();
            let active: Vec<String> = cp.active_depths.iter().map(|d| format!("{}", d)).collect();
            let var_order: Vec<String> = cp.global_var_order.iter()
                .map(|n| format!("\"{}\"", json_escape(n)))
                .collect();
            let idx_order: Vec<String> = cp.idx_order.iter()
                .map(|n| format!("\"{}\"", json_escape(n)))
                .collect();
            format!(
                "{{\"index\":\"{}\",\"idx_order\":[{}],\"specs\":[{}],\"var_depths\":[{}],\"active_depths\":[{}],\"var_order\":[{}]}}",
                json_escape(&cp.index_name),
                idx_order.join(","),
                specs.join(","),
                var_depths.join(","),
                active.join(","),
                var_order.join(","),
            )
        }
    }
}

impl VMProgram {
    pub fn to_json(&self) -> String {
        let insts: Vec<String> = self.instructions.iter().map(|inst| {
            format!(
                "{{\"op\":\"{:?}\",\"p1\":{},\"p2\":{},\"p3\":{},\"p4\":{}}}",
                inst.op, inst.p1, inst.p2, inst.p3,
                instruction_data_json(&inst.p4)
            )
        }).collect();

        let var_names: Vec<String> = self.var_names.iter()
            .map(|n| format!("\"{}\"", json_escape(n)))
            .collect();
        let depth_var: Vec<String> = self.depth_var.iter()
            .map(|(a, b)| format!("[{},{}]", a, b))
            .collect();

        format!(
            "{{\"instructions\":[{}],\"num_registers\":{},\"num_vars\":{},\"var_names\":[{}],\"depth_var\":[{}],\"same_var_constraints\":[],\"history\":{}}}",
            insts.join(","),
            self.num_registers,
            self.num_vars,
            var_names.join(","),
            depth_var.join(","),
            self.history,
        )
    }
}

#[derive(Clone)]
pub struct VMProgram {
    pub instructions: Vec<Instruction>,
    pub num_registers: usize,
    pub num_vars: usize,
    pub var_names: Vec<String>,
    pub depth_var: Vec<(usize, usize)>,
    pub same_var_constraints: Vec<(i32, Vec<(usize, usize)>)>,
    pub history: bool,
}

/// Shared, refcounted handle to a compiled `VMProgram`.
///
/// Crosses FFI as 1 boxed pointer via `#[slot_struct]` (mirrors `CursorHandle`).
/// Cloning is a cheap `Arc` clone, so it is safe to pass as a by-value IDL
/// parameter on every `run_vm` call (e.g. prepared statements). There is no
/// `free_program` — the `Arc` refcount + `Drop` / `FFIResource.__del__` handle
/// cleanup, avoiding the `u64`-handle + explicit-close anti-pattern.
#[derive(Clone)]
pub struct ProgramHandle {
    pub program: Arc<VMProgram>,
}

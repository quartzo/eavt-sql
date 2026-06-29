use std::sync::Arc;

use dynspire_commons::query_engine::VMResultStream;
use dynspire_commons::transactor::query_codec;
use dynspire_commons::value::Value;

use crate::engine::vm::{VM, VMEngine, EngineError};
use crate::engine::opcodes::VMProgram;

pub struct VMSession {
    vm: VM,
    done: bool,
}

impl VMSession {
    pub fn new(
        program: Arc<VMProgram>,
        engine: Arc<dyn VMEngine + Send + Sync>,
        params: Vec<Value>,
        limit: Option<usize>,
        current_t: u64,
        as_of_us: Option<u64>,
    ) -> Self {
        let vm = VM::new(program, engine, params, limit, current_t, as_of_us);
        Self { vm, done: false }
    }
}

impl VMResultStream for VMSession {
    fn next_batch(&mut self, out: &mut Vec<u8>, max_rows: usize) -> Result<bool, String> {
        if self.done {
            return Ok(false);
        }

        let mut rows: Vec<Vec<Value>> = Vec::new();
        let more = self
            .vm
            .run_batch(&mut rows, max_rows)
            .map_err(|e: EngineError| e.0)?;

        for row in &rows {
            out.extend_from_slice(&(row.len() as u32).to_be_bytes());
            for v in row {
                query_codec::encode_one(out, v);
            }
        }

        if !more {
            self.done = true;
        }
        Ok(more)
    }
}

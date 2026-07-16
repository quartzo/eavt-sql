mod compiler;
mod datalog;
mod scheme_compile;

pub use spier_datalog::CompileStats;

use spier_datalog::DatalogNumIRSt;
use spier_planner::{Planner, PlannerEngine, QueryPlanSt};
use spier_query_ir::CompiledProgram;
use spier_sql_parse::{RustStmt, RustStmtSt};
use std::sync::Arc;
use spier_value::query_codec::decode_values;

/// Compiler output — crosses FFI as 1 boxed pointer.
/// Carries the compiled program and plan traces (for EXPLAIN).
#[derive(Clone)]
pub struct CompileResultSt {
    pub program: CompiledProgram,
    pub traces: Vec<spier_planner::PlanTrace>,
}

pub trait CompilerEngine: Send + Sync {
    fn compile_select(&self, num_ir: DatalogNumIRSt) -> Result<CompileResultSt, String>;
    fn compile_dml_scan(
        &self,
        stmt: RustStmtSt,
        num_ir: DatalogNumIRSt,
        sql_params: &[u8],
    ) -> Result<CompileResultSt, String>;
    fn compile_dml_direct(
        &self,
        stmt: RustStmtSt,
        sql_params: &[u8],
    ) -> Result<CompileResultSt, String>;
}

/// Pure Rust SQL compiler. just implements [`CompilerEngine`].
pub struct Compiler {
    planner: Planner,
}

impl Compiler {
    pub fn new() -> Self {
        Self {
            planner: Planner::new(),
        }
    }

    fn plan(&self, num_ir: DatalogNumIRSt) -> Result<QueryPlanSt, String> {
        self.planner.plan(num_ir)
    }
}

impl Default for Compiler {
    fn default() -> Self {
        Self::new()
    }
}

impl CompilerEngine for Compiler {
    fn compile_select(&self, num_ir: DatalogNumIRSt) -> Result<CompileResultSt, String> {
        let plan_st = self.plan(num_ir)?;
        let result = compiler::compile_from_plan(&plan_st.plan)?;
        Ok(CompileResultSt {
            program: CompiledProgram::Vm(Arc::new(result.program)),
            traces: result.traces,
        })
    }

    fn compile_dml_scan(
        &self,
        stmt: RustStmtSt,
        num_ir: DatalogNumIRSt,
        sql_params: &[u8],
    ) -> Result<CompileResultSt, String> {
        let params = decode_values(sql_params)?;
        let plan_st = self.plan(num_ir)?;
        let plan = &plan_st.plan;

        if plan.join_patterns.is_empty() && plan.lookups.is_empty() {
            return Err("UPDATE/DELETE requires WHERE conditions".to_string());
        }

        let find_vars: Vec<String> = plan
            .find_vars
            .iter()
            .map(|fv| match fv {
                spier_datalog::FindVar::Var(name) | spier_datalog::FindVar::Const(name, _) => {
                    name.clone()
                }
            })
            .collect();

        match stmt.stmt {
            RustStmt::Update(ref update_stmt) => {
                let first_alias = update_stmt
                    .clauses
                    .first()
                    .map(|c| c.alias.clone())
                    .unwrap_or_else(|| "D1".to_string());
                let all_set_values: Vec<(String, Vec<spier_sql_parse::RustInsertValue>)> =
                    update_stmt
                        .clauses
                        .iter()
                        .map(|c| (c.alias.clone(), c.values.clone()))
                        .collect();
                let target_evar = format!("_e_{}", first_alias.to_lowercase());

                let program = compiler::compile_triejoin_update(
                    plan,
                    &plan.range_bounds,
                    &find_vars,
                    &all_set_values,
                    &target_evar,
                )?;
                Ok(CompileResultSt {
                    program: CompiledProgram::Vm(Arc::new(program)),
                    traces: plan.plan_traces.clone(),
                })
            }
            RustStmt::Delete(ref delete_stmt) => {
                let first_alias = delete_stmt
                    .conditions
                    .first()
                    .map(|c| c.left.alias.clone())
                    .unwrap_or_else(|| "D1".to_string());
                let target_evar = format!("_e_{}", first_alias.to_lowercase());

                let retract_pairs = compiler::resolve_delete_pairs(delete_stmt, &params)?;

                let program = compiler::compile_triejoin_delete(
                    plan,
                    &plan.range_bounds,
                    &find_vars,
                    &target_evar,
                    &retract_pairs,
                )?;
                Ok(CompileResultSt {
                    program: CompiledProgram::Vm(Arc::new(program)),
                    traces: plan.plan_traces.clone(),
                })
            }
            _ => Err("compile_dml_scan only supports UPDATE/DELETE".to_string()),
        }
    }

    fn compile_dml_direct(
        &self,
        stmt: RustStmtSt,
        sql_params: &[u8],
    ) -> Result<CompileResultSt, String> {
        let params = decode_values(sql_params)?;
        let program = match &stmt.stmt {
            RustStmt::Upsert(upsert_stmt) => {
                let scheme = scheme_compile::compile_upsert_scheme(upsert_stmt, &params)?;
                return Ok(CompileResultSt {
                    program: CompiledProgram::Scheme(scheme),
                    traces: Vec::new(),
                });
            }
            RustStmt::Attribute(attr_stmt) => {
                CompiledProgram::Vm(Arc::new(compiler::compile_rust_attribute(attr_stmt)))
            }
            RustStmt::Partition(part_stmt) => {
                CompiledProgram::Vm(Arc::new(compiler::compile_rust_partition(part_stmt)))
            }
            RustStmt::Delete(delete_stmt) => {
                let pairs = compiler::resolve_delete_pairs(delete_stmt, &params)?;
                let entity_val = compiler::resolve_delete_entity(delete_stmt, &params)?;
                CompiledProgram::Vm(Arc::new(compiler::compile_rust_delete_direct(&entity_val, &pairs)?))
            }
            _ => {
                return Err(
                    "compile_dml_direct only supports UPSERT/Attribute/Partition/Delete-direct"
                        .to_string(),
                )
            }
        };
        Ok(CompileResultSt {
            program,
            traces: Vec::new(),
        })
    }
}

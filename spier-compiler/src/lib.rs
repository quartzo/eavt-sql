mod compiler;
mod datalog;
mod scheme_compile;

pub use spier_datalog::CompileStats;

use spier_datalog::DatalogNumIRSt;
use spier_planner::{Planner, PlannerEngine, QueryPlanSt};
use spier_query_ir::CompiledProgram;
use spier_sql_parse::{RustStmt, RustStmtSt};
use spier_value::query_codec::decode_values;

fn select_scheme_result(
    scheme_program: spier_scheme::SchemeProgram,
    meta: spier_query_ir::SelectSchemeMeta,
    plan: &spier_planner::QueryPlanResult,
) -> CompileResultSt {
    CompileResultSt {
        program: CompiledProgram::SelectScheme(scheme_program, meta),
        traces: plan.plan_traces.clone(),
    }
}

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
        let plan = &plan_st.plan;
        let total_proj_len = plan.find_vars.len();
        let (scheme_program, meta) = scheme_compile::compile_select_scheme(
            plan,
            total_proj_len,
            &plan.find_vars,
        )?;
        Ok(select_scheme_result(scheme_program, meta, plan))
    }

    fn compile_dml_scan(
        &self,
        stmt: RustStmtSt,
        num_ir: DatalogNumIRSt,
        sql_params: &[u8],
    ) -> Result<CompileResultSt, String> {
        let _params = decode_values(sql_params)?;
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
                let (scheme_program, meta) = scheme_compile::compile_update_scheme(
                    plan,
                    &find_vars,
                    update_stmt,
                )?;
                Ok(select_scheme_result(scheme_program, meta, plan))
            }
            RustStmt::Delete(ref delete_stmt) => {
                let first_alias = delete_stmt
                    .conditions
                    .first()
                    .map(|c| c.left.alias.clone())
                    .unwrap_or_else(|| "D1".to_string());
                let target_evar = format!("_e_{}", first_alias.to_lowercase());

                let (scheme_program, meta) = scheme_compile::compile_delete_scheme(
                    plan,
                    &find_vars,
                    &target_evar,
                    delete_stmt,
                )?;
                Ok(select_scheme_result(scheme_program, meta, plan))
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
        match &stmt.stmt {
            RustStmt::Upsert(upsert_stmt) => {
                let scheme = scheme_compile::compile_upsert_scheme(upsert_stmt, &params)?;
                Ok(CompileResultSt {
                    program: CompiledProgram::Scheme(scheme),
                    traces: Vec::new(),
                })
            }
            RustStmt::Attribute(attr_stmt) => {
                let scheme = scheme_compile::compile_attribute_scheme(attr_stmt);
                Ok(CompileResultSt {
                    program: CompiledProgram::Scheme(scheme),
                    traces: Vec::new(),
                })
            }
            RustStmt::Partition(part_stmt) => {
                let scheme = scheme_compile::compile_partition_scheme(part_stmt);
                Ok(CompileResultSt {
                    program: CompiledProgram::Scheme(scheme),
                    traces: Vec::new(),
                })
            }
            RustStmt::Delete(delete_stmt) => {
                let pairs = compiler::resolve_delete_pairs(delete_stmt, &params)?;
                let entity_val = compiler::resolve_delete_entity(delete_stmt, &params)?;
                let scheme = scheme_compile::compile_delete_direct_scheme(&entity_val, &pairs);
                Ok(CompileResultSt {
                    program: CompiledProgram::Scheme(scheme),
                    traces: Vec::new(),
                })
            }
            _ => Err(
                "compile_dml_direct only supports UPSERT/Attribute/Partition/Delete-direct"
                    .to_string(),
            ),
        }
    }
}

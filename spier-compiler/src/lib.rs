use std::collections::HashMap;

mod compiler;
mod datalog;

use dynspire_commons::compiler::CompileResultSt;
use dynspire_commons::datalog::{DatalogNumIRSt, FindVar};
use dynspire_commons::planner::{DynSpirePlanner, PlannerEngine};
use dynspire_commons::sql_parse::{RustStmt, RustStmtSt};
use dynspire_commons::transactor::query_codec::decode_values;

include!(concat!(env!("OUT_DIR"), "/compiler_spier.rs"));

struct CompilerState {
    planner: DynSpirePlanner,
}

fn init(config: &HashMap<String, String>) -> Result<CompilerState, String> {
    let planner = DynSpirePlanner::connect("spier_planner", config)?;
    Ok(CompilerState { planner })
}

impl CompilerEngine for CompilerState {
    fn compile_select(&self, num_ir: DatalogNumIRSt) -> Result<CompileResultSt, String> {
        let plan_st = self.planner.plan(num_ir)?;
        let result = compiler::compile_from_plan(&plan_st.plan)?;
        Ok(CompileResultSt {
            program: result.program,
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
        let plan_st = self.planner.plan(num_ir)?;
        let plan = &plan_st.plan;

        if plan.join_patterns.is_empty() && plan.lookups.is_empty() {
            return Err("UPDATE/DELETE requires WHERE conditions".to_string());
        }

        let find_vars: Vec<String> = plan.find_vars.iter().map(|fv| match fv {
            FindVar::Var(name) | FindVar::Const(name, _) => name.clone(),
        }).collect();

        match stmt.stmt {
            RustStmt::Update(ref update_stmt) => {
                let first_alias = update_stmt.clauses.first()
                    .map(|c| c.alias.clone())
                    .unwrap_or_else(|| "D1".to_string());
                let all_set_values: Vec<(String, Vec<dynspire_commons::sql_parse::RustInsertValue>)> = update_stmt.clauses.iter()
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
                    program,
                    traces: plan.plan_traces.clone(),
                })
            }
            RustStmt::Delete(ref delete_stmt) => {
                let first_alias = delete_stmt.conditions.first()
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
                    program,
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
                compiler::compile_upsert(upsert_stmt, &params)?
            }
            RustStmt::Attribute(attr_stmt) => {
                compiler::compile_rust_attribute(attr_stmt)
            }
            RustStmt::Partition(part_stmt) => {
                compiler::compile_rust_partition(part_stmt)
            }
            RustStmt::Delete(delete_stmt) => {
                // Direct DELETE (with eid condition, no scan needed)
                let pairs = compiler::resolve_delete_pairs(delete_stmt, &params)?;
                let entity_val = compiler::resolve_delete_entity(delete_stmt, &params)?;
                compiler::compile_rust_delete_direct(&entity_val, &pairs)?
            }
            _ => return Err("compile_dml_direct only supports UPSERT/Attribute/Partition/Delete-direct".to_string()),
        };
        Ok(CompileResultSt {
            program,
            traces: Vec::new(),
        })
    }
}

impl_compiler_spier!(CompilerState, init, "spier_compiler");

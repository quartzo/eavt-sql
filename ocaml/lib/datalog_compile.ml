(* datalog_compile.ml — orchestration, mirroring
   nim_compiler/datalog_compile.nim:
   parse (query_edn) → resolveIr → computePlanStats → buildQueryPlan
   → compileSelectScheme.  Returns the program S-expr (wire output)
   plus the :find var names. *)

open Datalog_ast
module S = Sexpr

exception Compile_error of string

let compile_datalog_query_debug (text : string) (cstats : Compile_stats.t)
  : Sexpr.t * string list * string list * Planner.iter_plan_data list =
  let ir, find_vars =
    try Query_edn.parse_datalog_query text
    with
    | Query_edn.Datalog_syntax_error msg -> raise (Compile_error msg)
    | Resolve.Resolve_failed ->
      raise (Compile_error "attribute resolution failed")
  in
  let resolved_ok =
    try Resolve.resolve_ir ir cstats
    with Resolve.Resolve_failed ->
      raise (Compile_error "attribute resolution failed")
  in
  if not resolved_ok then raise (Compile_error "attribute resolution failed");
  let plan_stats = Resolve.compute_plan_stats ir cstats in
  let join_patterns = List.map Pattern.of_ir ir.patterns in
  let plan = Planner.build_query_plan join_patterns find_vars
      (List.map fst ir.range_bounds) plan_stats in
  plan.Planner.history <- ir.history;
  plan.Planner.exists_mode <- ir.exists_mode;
  plan.Planner.find_vars <- ir.find_vars;
  plan.Planner.range_bounds <-
    Planner.convert_range_bounds ir.range_bounds;
  let prog = Scheme_compile.compile_select_scheme plan in
  (prog, find_vars, plan.Planner.ordered_vars, plan.Planner.iter_plans)

let compile_datalog_query (text : string) (cstats : Compile_stats.t)
  : Sexpr.t * string list =
  let (prog, fv, _, _) = compile_datalog_query_debug text cstats in
  (prog, fv)

(* pattern.ml — planner-facing pattern view, mirroring
   nim_datalog/pattern.nim. *)

open Datalog_ast

type index_def = string * string array

let index_orders : index_def list =
  [ ("EAVT", [| "e"; "a"; "v"; "t"; "added" |]);
    ("AEVT", [| "a"; "e"; "v"; "t"; "added" |]);
    ("AVET", [| "a"; "v"; "e"; "t"; "added" |]);
    ("VAET", [| "v"; "a"; "e"; "t"; "added" |]) ]

let index_entry (index_name : string) : string array =
  let upper = String.uppercase_ascii index_name in
  match List.assoc_opt upper index_orders with
  | Some order -> order
  | None -> [| "e"; "a"; "v" |]

let is_lookup (p : pattern) : bool =
  match (p.e, p.a, p.v) with
  | Ds_const (Bv_missing _), _, _ -> false
  | _, Ds_const (Bv_missing _), _ -> false
  | _, _, Ds_const (Bv_missing _) -> false
  | Ds_const _, Ds_const _, Ds_const _ -> true
  | _ -> false

let contains_var_in_eav (p : pattern) (var_name : string) : bool =
  List.exists
    (fun (s : slot) -> match s with Ds_var n -> n = var_name | _ -> false)
    [ p.e; p.a; p.v; p.t; p.added ]

(* ir-pattern → planner-pattern (Nim toPattern: same shape) *)
let of_ir (p : Datalog_ast.pattern) : Datalog_ast.pattern = p

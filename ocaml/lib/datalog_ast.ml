(* datalog_ast.ml — Datalog IR, mirroring nim_datalog/datalog_ast.nim.
   Nim uses ref objects with per-case fields; here a single variant
   covers the BoundValue cases and slots are a 3-way variant. *)

type bound_value =
  | Bv_int of int64
  | Bv_float of float
  | Bv_str of string
  | Bv_attr of string
  | Bv_resolved_attr of int32 * string * bool * bool  (* id, name, isRef, isIndexed *)
  | Bv_var of string
  | Bv_missing of string
  | Bv_param of int32
  | Bv_bool of bool

type slot =
  | Ds_var of string
  | Ds_const of bound_value
  | Ds_missing

type find_var =
  | Fv_var of string
  | Fv_const of string * bound_value

type pattern = {
  e : slot;
  a : slot;
  v : slot;
  t : slot;
  added : slot;
}

type range_cond = string * bound_value  (* op, value *)

type ir = {
  mutable patterns : pattern list;
  mutable find_vars : find_var list;
  (* varName -> branches -> conditions; Nim Table iteration order is not
     observable in the wire output (all consumers are lookup tables) *)
  mutable range_bounds : (string * range_cond list list) list;
  mutable star : bool;
  mutable exists_mode : bool;
  mutable has_conditions : bool;
  mutable history : bool;
}

let empty_ir () =
  { patterns = []; find_vars = []; range_bounds = [];
    star = false; exists_mode = false; has_conditions = false;
    history = false }

let slot (p : pattern) (pos : string) : slot =
  match pos with
  | "e" -> p.e
  | "a" -> p.a
  | "v" -> p.v
  | "t" -> p.t
  | "added" -> p.added
  | _ -> p.t

let range_bounds_lookup (ir : ir) (name : string) : range_cond list list option =
  match List.assoc_opt name ir.range_bounds with
  | Some v -> Some v
  | None -> None

let range_bounds_set (ir : ir) (name : string) (v : range_cond list list) : unit =
  ir.range_bounds <-
    (match List.assoc_opt name ir.range_bounds with
     | Some _ -> List.map (fun (k, w) -> if k = name then (name, v) else (k, w)) ir.range_bounds
     | None -> ir.range_bounds @ [ (name, v) ])

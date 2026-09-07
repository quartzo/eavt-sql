(* resolve.ml — attribute resolution + plan stats, mirroring
   nim_datalog/resolve.nim. *)

open Datalog_ast
module S = Compile_stats
module P = Pattern

exception Resolve_failed

let resolve_ir (ir : ir) (s : S.t) : bool =
  (* Only the a slot carries a bvAttr const from the reader; resolve it
     against attrIds — id==0 (absent) fails the compile. *)
  ir.patterns <-
    List.map
      (fun (p : pattern) ->
        match p.a with
        | Ds_const (Bv_attr name) ->
          let id =
            match S.attr_id s name with
            | Some id -> id
            | None -> 0l
          in
          if Int32.equal id 0l then raise Resolve_failed
          else
            let is_ref = S.is_ref s name in
            let is_indexed = S.is_indexed s name in
            { p with a = Ds_const (Bv_resolved_attr (id, name, is_ref, is_indexed)) }
        | _ -> p)
      ir.patterns;
  (* range bounds may carry attr consts too (rare) *)
  ir.range_bounds <-
    List.map
      (fun (vn, branches) ->
        (vn,
         List.map
           (fun (branch : range_cond list) ->
             List.map
               (fun (op, bv) ->
                 match bv with
                 | Bv_attr name ->
                   (match S.attr_id s name with
                    | Some id ->
                      (op, Bv_resolved_attr (id, name, S.is_ref s name, S.is_indexed s name))
                    | None -> (op, bv))
                 | _ -> (op, bv))
               branch)
           branches))
      ir.range_bounds;
  true

(* plan stats — the same estimates table the Nim planner consumes *)
type plan_stats = {
  total_eavt : float;
  estimates : (int * string * string, float) Hashtbl.t;
}

let compute_plan_stats (ir : ir) (s : S.t) : plan_stats =
  let total_eavt =
    let v = match List.assoc_opt "EAVT:" s.index_estimates with Some f -> f | None -> 1.0 in
    Float.max v 1.0
  in
  let estimates : (int * string * string, float) Hashtbl.t = Hashtbl.create 64 in
  List.iteri
    (fun pat_idx (pattern : pattern) ->
      List.iter
        (fun (index_name, index_order) ->
          Array.iteri
            (fun _pos pos ->
              match Datalog_ast.slot pattern pos with
              | Ds_var var_name ->
                let pos_in_idx =
                  let rec find i =
                    if i >= Array.length index_order then -1
                    else if index_order.(i) = pos then i
                    else find (i + 1)
                  in
                  find 0
                in
                let bound_vals =
                  let rec collect bi acc =
                    if bi >= pos_in_idx then List.rev acc
                    else
                      let before_slot = Datalog_ast.slot pattern index_order.(bi) in
                      let bv =
                        match before_slot with
                        | Ds_const (Bv_int i) -> Int64.to_int i
                        | Ds_const (Bv_resolved_attr (id, _, _, _)) -> Int32.to_int id
                        | _ -> 0
                      in
                      collect (bi + 1) (bv :: acc)
                  in
                  collect 0 []
                in
                let key = ref (index_name ^ ":") in
                List.iter
                  (fun bv -> if bv <> 0 then key := !key ^ string_of_int bv ^ ":")
                  bound_vals;
                let est =
                  match List.assoc_opt !key s.index_estimates with
                  | Some f -> Float.max f 1.0
                  | None -> total_eavt
                in
                Hashtbl.replace estimates (pat_idx, index_name, var_name) est
              | _ -> ())
            index_order)
        P.index_orders)
    ir.patterns;
  { total_eavt; estimates }

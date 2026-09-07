(* query_edn.ml — Datalog EDN surface → Datalog IR, mirroring
   nim_datalog/query_edn.nim.  Operates on Edn.t values from edn.ml
   (List covers both [] and ()); keywords carry the name WITHOUT the
   leading colon (edn.ml convention), so enum-style keyword values
   re-add it as ":" ^ name, exactly like the Nim reader. *)

exception Datalog_syntax_error of string

open Datalog_ast

let range_ops = [ ">"; "<"; ">="; "<="; "="; "!=" ]

let is_var_sym (e : Edn.t) : bool =
  match e with
  | Edn.Symbol s -> String.length s > 0 && s.[0] = '?'
  | _ -> false

let var_name (e : Edn.t) : string =
  match e with
  | Edn.Symbol s -> String.sub s 1 (String.length s - 1)
  | _ -> assert false

let is_blank (e : Edn.t) : bool = e = Edn.Symbol "_"

let parse_value (e : Edn.t) (params : (string * int32) list) : bound_value =
  if is_var_sym e then
    let vn = var_name e in
    match List.assoc_opt vn params with
    | Some idx -> Bv_param idx
    | None ->
      raise (Datalog_syntax_error
               ("datalog: unbound var ?" ^ vn ^ " in value position (declare it in :in)"))
  else
    match e with
    | Edn.Str s -> Bv_str s
    | Edn.Int i -> Bv_int i
    | Edn.Float f -> Bv_float f
    | Edn.Bool b -> Bv_bool b
    | Edn.Keyword kw -> Bv_str (":" ^ kw)  (* enum-style keyword value *)
    | _ -> raise (Datalog_syntax_error "datalog: unsupported value")

let parse_pattern (p : Edn.t) (ir : ir) (params : (string * int32) list) : unit =
  match p with
  | Edn.List [ e_slot; a_slot; v_slot ] ->
    let e =
      if is_var_sym e_slot then
        let vn = var_name e_slot in
        (* :in var in slot E binds at runtime — param (probe/seek) *)
        (match List.assoc_opt vn params with
         | Some idx -> Ds_const (Bv_param idx)
         | None -> Ds_var vn)
      else if is_blank e_slot then Ds_missing
      else (match e_slot with
            | Edn.Int i -> Ds_const (Bv_int i)
            | _ -> raise (Datalog_syntax_error
                            "datalog: e slot must be a var, _ or eid"))
    in
    let attr =
      match a_slot with
      | Edn.Keyword kw ->
        (* SQL-style surface normalizes dot → slash BEFORE the ns check *)
        let attr =
          if String.contains kw '.' then
            String.map (fun c -> if c = '.' then '/' else c) kw
          else kw
        in
        if not (String.contains attr '/') then
          raise (Datalog_syntax_error ("datalog: attr keyword must be namespaced: :" ^ kw));
        attr
      | _ -> raise (Datalog_syntax_error
                      "datalog: attr slot must be a keyword like :person/name")
    in
    let a = Ds_const (Bv_attr attr) in
    let v =
      if is_var_sym v_slot then
        let vn = var_name v_slot in
        (match List.assoc_opt vn params with
         | Some idx -> Ds_const (Bv_param idx)
         | None -> Ds_var vn)
      else if is_blank v_slot then Ds_missing
      else Ds_const (parse_value v_slot params)
    in
    ir.patterns <- ir.patterns @ [ { e; a; v; t = Ds_missing; added = Ds_missing } ]
  | _ -> raise (Datalog_syntax_error
                  "datalog: pattern must be a 3-element vector [e attr v]")

let pred_key (op_expr : Edn.t) : string =
  match op_expr with
  | Edn.Keyword op when List.mem op range_ops -> op
  | Edn.Keyword op ->
    raise (Datalog_syntax_error
             ("datalog: unsupported predicate op :" ^ op ^
              " (supported: > < >= <= = !=)"))
  | _ -> raise (Datalog_syntax_error
                  "datalog: predicate op must be a keyword like :>")

let is_op_sym (e : Edn.t) : bool =
  match e with Edn.Symbol s -> List.mem s range_ops | _ -> false

let add_range (ir : ir) (vn : string) (branch : int) (cond : range_cond) : unit =
  let branches = match range_bounds_lookup ir vn with Some b -> b | None -> [] in
  let arr = Array.make (max (List.length branches) (branch + 1)) [] in
  List.iteri (fun i b -> arr.(i) <- b) branches;
  arr.(branch) <- arr.(branch) @ [ cond ];
  range_bounds_set ir vn (Array.to_list arr)

let parse_predicate (p : Edn.t) (ir : ir) (params : (string * int32) list)
    (branch : int) : unit =
  let is_in head =
    match head with
    | Edn.Symbol "in" -> true
    | Edn.Keyword "in" -> true
    | _ -> false
  in
  match p with
  | Edn.List (head :: rest) when rest <> [] && is_in head ->
    (* [(in ?var v1 v2 ...)] — disjunction of equalities *)
    let var_expr = List.hd rest in
    if not (is_var_sym var_expr) then
      raise (Datalog_syntax_error "datalog: IN var must be ?var");
    let vn = var_name var_expr in
    List.iter
      (fun item -> add_range ir vn branch ("in", parse_value item params))
      (List.tl rest)
  | Edn.List [ op_expr; var_expr; val_expr ] ->
    let op =
      if is_op_sym op_expr then
        (match op_expr with Edn.Symbol s -> s | _ -> assert false)
      else pred_key op_expr
    in
    if not (is_var_sym var_expr) then
      raise (Datalog_syntax_error "datalog: predicate var must be ?var");
    let vn = var_name var_expr in
    add_range ir vn branch (op, parse_value val_expr params)
  | _ -> raise (Datalog_syntax_error
                  "datalog: predicate must be [(op var value)]")

let rec parse_where_element (p0 : Edn.t) (ir : ir) (params : (string * int32) list)
    (branch : int) : unit =
  (* The EDN reader nests predicate vectors: [(> ?v 5)] arrives as
     [[> ?v 5]].  Unwrap one level, then route. *)
  let p =
    match p0 with
    | Edn.List [ Edn.List inner ] when inner <> [] ->
      let head = List.hd inner in
      let inner_is_route =
        is_op_sym head
        || head = Edn.Symbol "or" || head = Edn.Symbol "in"
        || (match head with
            | Edn.Keyword kw -> kw = "or" || kw = "in" || List.mem kw range_ops
            | _ -> false)
      in
      if inner_is_route then Edn.List inner else p0
    | _ -> p0
  in
  let head_is_or =
    match p with
    | Edn.List (head :: _) ->
      head = Edn.Symbol "or" ||
             (match head with Edn.Keyword "or" -> true | _ -> false)
    | _ -> false
  in
  if head_is_or then
    match p with
    | Edn.List (_ :: items) ->
      List.iteri
        (fun i item -> parse_where_element item ir params i)  (* or-item = branch *)
        items
    | _ -> assert false
  else
    match p with
    | Edn.List (head :: _) when
        is_op_sym head
        || head = Edn.Symbol "in"
        || (match head with
            | Edn.Keyword kw -> kw = "in" || List.mem kw range_ops
            | _ -> false) ->
      parse_predicate p ir params branch
    | _ -> parse_pattern p ir params

type section = Sec_none | Sec_find | Sec_in | Sec_where

let parse_datalog_query (src : string) : ir * string list =
  let top =
    try Edn.read_edn src
    with Edn.Edn_error msg ->
      raise (Datalog_syntax_error ("datalog: EDN parse error: " ^ msg))
  in
  let items =
    match top with
    | Edn.List items -> items
    | _ -> raise (Datalog_syntax_error "datalog: query must start with [:find ...]")
  in
  let starts_find =
    match items with
    | Edn.Keyword "find" :: _ -> true
    | _ -> false
  in
  if items = [] || not starts_find then
    raise (Datalog_syntax_error "datalog: query must start with [:find ...]");
  let ir = empty_ir () in
  let params = ref [] in
  let param_idx = ref 0l in
  let section = ref Sec_find in
  List.iteri
    (fun i el ->
      if i = 0 then ()
      else
        match el with
        | Edn.Keyword kw ->
          (match kw with
           | "find" -> section := Sec_find
           | "in" -> section := Sec_in
           | "where" -> section := Sec_where
           | "history" -> ir.history <- true; section := Sec_none
           | other -> raise (Datalog_syntax_error
                               ("datalog: unknown query section :" ^ other)))
        | _ ->
          (match !section with
           | Sec_find ->
             if not (is_var_sym el) then
               raise (Datalog_syntax_error
                        "datalog: :find takes vars like ?name");
             ir.find_vars <- ir.find_vars @ [ Fv_var (var_name el) ]
           | Sec_in ->
             (match el with
              | Edn.Symbol "$" -> ()  (* the db input *)
              | _ when is_var_sym el ->
                param_idx := Int32.succ !param_idx;
                params := !params @ [ (var_name el, !param_idx) ]
              | _ -> raise (Datalog_syntax_error
                              "datalog: :in takes $ and vars like ?x"))
           | Sec_where -> parse_where_element el ir !params 0
           | Sec_none ->
             raise (Datalog_syntax_error
                      "datalog: unexpected element outside a section"))
    )
    items;
  if ir.find_vars = [] then
    raise (Datalog_syntax_error "datalog: :find is required");
  if ir.patterns = [] then
    raise (Datalog_syntax_error
             "datalog: :where with at least one pattern is required");
  (* every range-predicate var must be bound by some pattern value slot *)
  List.iter
    (fun (vn, _) ->
      let bound =
        List.exists
          (fun (p : pattern) -> match p.v with Ds_var name -> name = vn | _ -> false)
          ir.patterns
      in
      if not bound then
        raise (Datalog_syntax_error
                 ("datalog: predicate var ?" ^ vn ^
                  " is not bound by any pattern value slot")))
    ir.range_bounds;
  let find_vars =
    List.map
      (function Fv_var n -> n | Fv_const (n, _) -> n)
      ir.find_vars
  in
  (ir, find_vars)

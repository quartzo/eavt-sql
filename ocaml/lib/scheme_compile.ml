(* scheme_compile.ml — plan → Scheme program, mirroring
   nim_compiler/scheme_compile.nim.  The output S-expression encodes to
   wire msgpack; the Fase-2 gate is byte-identity with the Nim output. *)

open Datalog_ast
module P = Pattern
module Pl = Planner
module S = Sexpr

let list (items : S.t list) : S.t = S.S_list items

(* Nim countdown(a, b): itera a downto b, inclusive *)
let range_dn (a : int) : int list =
  let rec loop n acc = if n < 0 then acc else loop (n - 1) (acc @ [ n ]) in
  loop a []

let plan_value_to_sexpr (pv : Pl.plan_value) : S.t =
  match pv with
  | Pl.Pv_value (i, f, s) ->
    if s <> "" then S.S_str s
    else if f <> 0.0 then S.S_float f
    else S.S_int i
  | Pl.Pv_param idx -> list [ S.S_keyword "param"; S.S_int (Int64.of_int32 idx) ]

let bound_to_sexpr (bv : bound_value) : S.t =
  match bv with
  | Bv_int i -> S.S_int i
  | Bv_float f -> S.S_float f
  | Bv_str s | Bv_attr s -> S.S_str s
  | Bv_resolved_attr (_, name, _, _) ->
    list [ S.S_keyword "intern-a"; S.S_str name ]
  | Bv_param idx -> list [ S.S_keyword "param"; S.S_int (Int64.of_int32 idx) ]
  | Bv_var n -> S.S_symbol ("?" ^ n)
  | Bv_bool b -> S.S_bool b
  | Bv_missing _ -> S.S_symbol "_"

let build_range_tree (branches : (string * Pl.plan_value) list list) : S.t =
  let build_branch (branch : (string * Pl.plan_value) list) : S.t =
    let in_vals = ref [] in
    let other_conds = ref [] in
    List.iter
      (fun (op, pv) ->
        if op = "in" then in_vals := !in_vals @ [ plan_value_to_sexpr pv ]
        else
          other_conds :=
            !other_conds @ [ list [ S.S_keyword op; plan_value_to_sexpr pv ] ])
      branch;
    (match !in_vals with
     | [ single ] ->
       other_conds := !other_conds @ [ list [ S.S_keyword "="; single ] ]
     | vs when List.length vs > 1 ->
       let eqs =
         List.fold_left
           (fun acc v -> acc @ [ list [ S.S_keyword "="; v ] ])
           [ S.S_keyword "or" ] vs
       in
       other_conds := !other_conds @ [ list eqs ]
     | _ -> ());
    match !other_conds with
    | [ single ] -> single
    | conds -> list ([ S.S_keyword "and" ] @ conds)
  in
  match branches with
  | [ single ] -> build_branch single
  | bs ->
    let branch_sexprs = List.map build_branch bs in
    list ([ S.S_keyword "or" ] @ branch_sexprs)

let rec replace_body_placeholder (expr : S.t) (replacement : S.t) : S.t =
  match expr with
  | S.S_symbol "__BODY__" -> replacement
  | S.S_list items -> list (List.map (fun it -> replace_body_placeholder it replacement) items)
  | other -> other

let rec flatten_begins (expr : S.t) : S.t =
  match expr with
  | S.S_list items ->
    let items = List.map flatten_begins items in
    (match items with
     | S.S_keyword "begin" :: rest ->
       let acc = ref [ S.S_keyword "begin" ] in
       List.iter
         (fun item ->
           match item with
           | S.S_list (S.S_keyword "begin" :: inner) ->
             acc := !acc @ inner
           | other -> acc := !acc @ [ other ])
         rest;
       list !acc
     | _ -> list items)
  | other -> other

let build_triejoin_scheme (plan : Pl.query_plan_result) (_find_vars : string list)
    (leaf_body : S.t) : Sexpr.t =
  let ordered_vars = plan.Pl.ordered_vars in
  let num_depths = List.length ordered_vars in
  let var_names_list = ref ordered_vars in
  List.iter
    (fun tn -> if not (List.mem tn !var_names_list) then var_names_list := !var_names_list @ [ tn ])
    plan.Pl.t_lookup_vars;
  (* trailingBindings is always empty in the datalog path — nada a adicionar *)
  let _var_names = !var_names_list in
  let scanner_bindings =
    List.mapi
      (fun ip_idx ip ->
        let scanner_name = "?s" ^ string_of_int ip_idx in
        let open_args =
          [ S.S_keyword "scanner-open"; S.S_str (String.uppercase_ascii ip.Pl.index_name) ]
          @ (if plan.Pl.history then [ S.S_bool true ] else [])
        in
        list [ S.S_symbol scanner_name; list open_args ])
      plan.Pl.iter_plans
  in
  let depth_ranges = Hashtbl.create 16 in
  List.iter
    (fun (var_name, branches) ->
      let found =
        let rec find i = function
          | [] -> -1
          | v :: rest -> if v = var_name then i else find (i + 1) rest
        in
        find 0 ordered_vars
      in
      if found >= 0 then Hashtbl.replace depth_ranges found (build_range_tree branches))
    plan.Pl.range_bounds;
  let bind_vals =
    List.map
      (fun ip ->
        List.filter_map
          (fun (pos_name, pv) ->
            let val_expr =
              match pv with
              | Pl.Pv_value (_, _, s) when s <> "" && pos_name = "a" ->
                list [ S.S_keyword "intern-a"; S.S_str s ]
              | _ -> plan_value_to_sexpr pv
            in
            Some (pos_name, val_expr))
          ip.Pl.bound_ints)
      plan.Pl.iter_plans
  in
  let bound_emitted =
    Array.make (List.length plan.Pl.iter_plans) [] in
  let scan_pos = Array.make (List.length plan.Pl.iter_plans) 0 in
  let ops = ref [] in
  for depth = 0 to num_depths - 1 do
    let var_name = List.nth ordered_vars depth in
    let scanners =
      List.filter_map
        (fun (ip_idx, ip) ->
          if List.exists (fun (d, _) -> d = depth) ip.Pl.var_depths then
            Some (S.S_symbol ("?s" ^ string_of_int ip_idx))
          else None)
        (List.mapi (fun i p -> (i, p)) plan.Pl.iter_plans)
    in
    if scanners <> [] then begin
      List.iteri
        (fun ip_idx ip ->
          if List.exists (fun (d, _) -> d = depth) ip.Pl.var_depths then begin
            let var_pos =
              match
                List.find_opt (fun (d, _) -> d = depth) ip.Pl.var_depths
              with
              | Some (_, p) -> p
              | None -> ""
            in
            (* bound positions before this depth *)
            List.iter
              (fun (pos_name, _) ->
                if not (List.mem pos_name bound_emitted.(ip_idx)) then
                  match List.assoc_opt pos_name (List.nth bind_vals ip_idx) with
                  | Some val_expr ->
                    bound_emitted.(ip_idx) <- pos_name :: bound_emitted.(ip_idx);
                    scan_pos.(ip_idx) <- scan_pos.(ip_idx) + 1;
                    let scanner_sym = S.S_symbol ("?s" ^ string_of_int ip_idx) in
                    ops :=
                      !ops
                      @ [ list [
                            S.S_keyword "begin";
                            list [ S.S_keyword "scanner-push"; scanner_sym; val_expr ];
                            S.S_symbol "__BODY__";
                            list [ S.S_keyword "scanner-pop"; scanner_sym ];
                          ] ]
                  | None -> ())
              (Pl.bound_positions_before ip depth);
            let target_idx =
              let rec find i =
                if i >= Array.length ip.Pl.idx_order then Array.length ip.Pl.idx_order
                else if ip.Pl.idx_order.(i) = var_pos then i
                else find (i + 1)
              in
              find 0
            in
            let rec drain_gaps () =
              if scan_pos.(ip_idx) < target_idx then begin
                let gap_slot = ip.Pl.idx_order.(scan_pos.(ip_idx)) in
                let is_handled =
                  List.exists
                    (fun (d, s) -> d <= depth && s = gap_slot)
                    ip.Pl.var_depths
                in
                if List.mem gap_slot bound_emitted.(ip_idx) || is_handled then begin
                  scan_pos.(ip_idx) <- scan_pos.(ip_idx) + 1;
                  drain_gaps ()
                end else begin
                  let gap_var = "?skip_" ^ gap_slot ^ "_" ^ String.lowercase_ascii ip.Pl.index_name in
                  scan_pos.(ip_idx) <- scan_pos.(ip_idx) + 1;
                  let scanner_sym = S.S_symbol ("?s" ^ string_of_int ip_idx) in
                  let gap_iter_var = S.S_symbol ("?it_" ^ gap_var) in
                  let gap_body = list [
                      S.S_keyword "begin";
                      list [ S.S_keyword "scanner-push"; scanner_sym; S.S_symbol gap_var ];
                      S.S_symbol "__BODY__";
                      list [ S.S_keyword "scanner-pop"; scanner_sym ];
                    ] in
                  let gap_while = list [
                      S.S_keyword "while";
                      list [ S.S_keyword "set!"; S.S_symbol gap_var;
                             list [ S.S_keyword "scanner-iterate-next"; gap_iter_var ] ];
                      gap_body;
                    ] in
                  let gap_expr = list [
                      S.S_keyword "begin";
                      list [ S.S_keyword "set!"; gap_iter_var;
                             list [ S.S_keyword "scanner-iterate-init"; scanner_sym; list [] ] ];
                      gap_while;
                    ] in
                  ops := !ops @ [ gap_expr ];
                  drain_gaps ()
                end
              end
            in
            drain_gaps ()
          end)
        plan.Pl.iter_plans;
      let ranges_tree =
        match Hashtbl.find_opt depth_ranges depth with
        | Some t -> t
        | None -> list []
      in
      let ranges_is_empty =
        match ranges_tree with S.S_list [] -> true | _ -> false
      in
      let ranges_expr = ref (list []) in
      let is_synthetic = ref false in
      List.iter
        (fun synth ->
          if synth.Pl.name = var_name then begin
            ranges_expr :=
              list [ S.S_keyword "ranges-create";
                     list [ S.S_keyword "="; S.S_symbol synth.Pl.source_var ] ];
            is_synthetic := true
          end)
        plan.Pl.synthetic_vars;
      if not !is_synthetic && not ranges_is_empty then
        ranges_expr := list [ S.S_keyword "ranges-create"; ranges_tree ];
      let init_args =
        List.fold_left (fun acc s -> acc @ [ s ]) [] scanners
        @ [ !ranges_expr ]
      in
      let iter_var = S.S_symbol ("?it_" ^ var_name) in
      let inner_items = ref [ S.S_keyword "begin" ] in
      if depth < num_depths - 1 then begin
        List.iter
          (fun s -> inner_items := !inner_items @ [ list [ S.S_keyword "scanner-push"; s; S.S_symbol var_name ] ])
          scanners;
        List.iteri
          (fun ip_idx ip ->
            List.iter
              (fun (d, p) ->
                if d = depth then bound_emitted.(ip_idx) <- p :: bound_emitted.(ip_idx))
              ip.Pl.var_depths)
          plan.Pl.iter_plans
      end;
      inner_items := !inner_items @ [ S.S_symbol "__BODY__" ];
      if depth < num_depths - 1 then
        List.iter
          (fun s -> inner_items := !inner_items @ [ list [ S.S_keyword "scanner-pop"; s ] ])
          scanners;
      let main_while = list [
          S.S_keyword "while";
          list [ S.S_keyword "set!"; S.S_symbol var_name;
                 list [ S.S_keyword "scanner-iterate-next"; iter_var ] ];
          list !inner_items;
        ] in
      let main_expr = list [
          S.S_keyword "begin";
          list [ S.S_keyword "set!"; iter_var;
                 list ([ S.S_keyword "scanner-iterate-init" ] @ init_args) ];
          main_while;
        ] in
      ops := !ops @ [ main_expr ]
    end
  done;
  (* trailing bindings *)
  let range_trees = Hashtbl.create 16 in
  List.iter
    (fun (var_name, branches) ->
      Hashtbl.replace range_trees var_name (build_range_tree branches))
    plan.Pl.range_bounds;
  List.iteri
    (fun ip_idx ip ->
      let trailing =
        List.filter_map
          (fun (pos_name, _) ->
            if List.mem pos_name bound_emitted.(ip_idx) then None
            else
              match List.assoc_opt pos_name (List.nth bind_vals ip_idx) with
              | Some val_expr -> Some (pos_name, val_expr)
              | None -> None)
          (Pl.all_bound_positions ip)
      in
      if trailing <> [] then begin
        let pos_to_var = Hashtbl.create 8 in
        List.iter
          (fun (d, p) ->
            if d < List.length ordered_vars then
              Hashtbl.replace pos_to_var p (S.S_symbol (List.nth ordered_vars d)))
          ip.Pl.var_depths;
        let pre_pushes = ref [] in
        List.iter
          (fun pos ->
            let is_trailing = List.exists (fun (pn, _) -> pn = pos) trailing in
            if not is_trailing && not (List.mem pos bound_emitted.(ip_idx)) then
              if Hashtbl.mem pos_to_var pos then pre_pushes := !pre_pushes @ [ pos ])
          (Array.to_list ip.Pl.idx_order);
        let last_idx = List.length trailing - 1 in
        List.iteri
          (fun i (pos_name, val_expr) ->
            bound_emitted.(ip_idx) <- pos_name :: bound_emitted.(ip_idx);
            let scanner_sym = S.S_symbol ("?s" ^ string_of_int ip_idx) in
            if i = last_idx then begin
              let last_ranges = ref (list [ S.S_keyword "="; val_expr ]) in
              Array.iteri
                (fun pos_idx pos ->
                  if pos <> pos_name && pos_idx < Array.length ip.Pl.idx_order then begin
                    match ip.Pl.specs.(pos_idx) with
                    | Pl.Sk_var var_name
                      when Hashtbl.mem range_trees var_name
                           && not (List.mem pos bound_emitted.(ip_idx))
                           && not (Hashtbl.mem pos_to_var pos) ->
                      last_ranges := Hashtbl.find range_trees var_name;
                      bound_emitted.(ip_idx) <- pos :: bound_emitted.(ip_idx)
                    | _ -> ()
                  end)
                ip.Pl.idx_order;
              let trail_var = "_" ^ pos_name ^ "_trail" in
              let trail_iter_var = S.S_symbol ("?it_" ^ trail_var) in
              let trail_ranges = list [ S.S_keyword "ranges-create"; !last_ranges ] in
              let trail_body = list [
                  S.S_keyword "begin";
                  list [ S.S_keyword "scanner-push"; scanner_sym; S.S_symbol trail_var ];
                  S.S_symbol "__BODY__";
                  list [ S.S_keyword "scanner-pop"; scanner_sym ];
                ] in
              let trail_while = list [
                  S.S_keyword "while";
                  list [ S.S_keyword "set!"; S.S_symbol trail_var;
                         list [ S.S_keyword "scanner-iterate-next"; trail_iter_var ] ];
                  trail_body;
                ] in
              let trail_items = ref [ S.S_keyword "begin" ] in
              List.iter
                (fun p ->
                  trail_items :=
                    !trail_items
                    @ [ list [ S.S_keyword "scanner-push"; scanner_sym;
                               Hashtbl.find pos_to_var p ] ])
                !pre_pushes;
              trail_items :=
                !trail_items
                @ [ list [ S.S_keyword "set!"; trail_iter_var;
                           list [ S.S_keyword "scanner-iterate-init"; scanner_sym;
                                  trail_ranges ] ] ];
              trail_items := !trail_items @ [ trail_while ];
              List.iter
                (fun _p ->
                  trail_items :=
                    !trail_items
                    @ [ list [ S.S_keyword "scanner-pop"; scanner_sym ] ])
                (range_dn (List.length !pre_pushes - 1));
              ops := !ops @ [ list !trail_items ]
            end else begin
              let push_items = ref [ S.S_keyword "begin" ] in
              List.iter
                (fun p ->
                  push_items :=
                    !push_items
                    @ [ list [ S.S_keyword "scanner-push"; scanner_sym;
                               Hashtbl.find pos_to_var p ] ])
                !pre_pushes;
              push_items :=
                !push_items
                @ [ list [ S.S_keyword "scanner-push"; scanner_sym; val_expr ] ];
              push_items := !push_items @ [ S.S_symbol "__BODY__" ];
              push_items :=
                !push_items
                @ [ list [ S.S_keyword "scanner-pop"; scanner_sym ] ];
              List.iter
                (fun _p ->
                  push_items :=
                    !push_items
                    @ [ list [ S.S_keyword "scanner-pop"; scanner_sym ] ])
                (range_dn (List.length !pre_pushes - 1));
              ops := !ops @ [ list !push_items ]
            end)
          trailing
      end)
    plan.Pl.iter_plans;
  (* non-iterated range vars *)
  let iterated_vars = ref [] in
  List.iter
    (fun ip ->
      List.iter
        (fun (d, _) ->
          if d < List.length ordered_vars then begin
            let v = List.nth ordered_vars d in
            if not (List.mem v !iterated_vars) then iterated_vars := v :: !iterated_vars
          end)
        ip.Pl.var_depths)
    plan.Pl.iter_plans;
  List.iteri
    (fun ip_idx ip ->
      let pos_to_var = Hashtbl.create 8 in
      List.iter
        (fun (d, p) ->
          if d < List.length ordered_vars then
            Hashtbl.replace pos_to_var p (S.S_symbol (List.nth ordered_vars d)))
        ip.Pl.var_depths;
      let emitted_pos = ref (List.map fst (List.nth bind_vals ip_idx)) in
      Array.iteri
        (fun pos_idx pos ->
          match ip.Pl.specs.(pos_idx) with
          | Pl.Sk_var spec_var when Hashtbl.mem range_trees spec_var
                                    && List.mem spec_var !iterated_vars = false
                                    && not (Hashtbl.mem pos_to_var pos)
                                    && not (List.mem pos !emitted_pos) ->
            emitted_pos := pos :: !emitted_pos;
            let scanner_sym = S.S_symbol ("?s" ^ string_of_int ip_idx) in
            let var_sym = S.S_symbol spec_var in
            let iter_var = S.S_symbol ("?it_" ^ spec_var) in
            let ranges_expr =
              list [ S.S_keyword "ranges-create"; Hashtbl.find range_trees spec_var ]
            in
            let pre_pushes = ref [] in
            Array.iteri
              (fun check_idx check_pos ->
                if check_idx < pos_idx then begin
                  if not (List.mem check_pos !emitted_pos) then
                    if Hashtbl.mem pos_to_var check_pos then
                      pre_pushes := !pre_pushes @ [ check_pos ]
                end)
              ip.Pl.idx_order;
            let inner_body = list [
                S.S_keyword "begin";
                list [ S.S_keyword "scanner-push"; scanner_sym; var_sym ];
                S.S_symbol "__BODY__";
                list [ S.S_keyword "scanner-pop"; scanner_sym ];
              ] in
            let inner_while = list [
                S.S_keyword "while";
                list [ S.S_keyword "set!"; var_sym;
                       list [ S.S_keyword "scanner-iterate-next"; iter_var ] ];
                inner_body;
              ] in
            let items = ref [ S.S_keyword "begin" ] in
            List.iter
              (fun p ->
                items :=
                  !items
                  @ [ list [ S.S_keyword "scanner-push"; scanner_sym;
                             Hashtbl.find pos_to_var p ] ])
              !pre_pushes;
            items :=
              !items
              @ [ list [ S.S_keyword "set!"; iter_var;
                         list [ S.S_keyword "scanner-iterate-init"; scanner_sym;
                                ranges_expr ] ] ];
            items := !items @ [ inner_while ];
            List.iter
              (fun _p ->
                items :=
                  !items @ [ list [ S.S_keyword "scanner-pop"; scanner_sym ] ])
              (range_dn (List.length !pre_pushes - 1));
            ops := !ops @ [ list !items ]
          | _ -> ())
        ip.Pl.idx_order)
    plan.Pl.iter_plans;
  (* wrap __BODY__ placeholders *)
  let body = ref leaf_body in
  List.iter
    (fun i -> body := replace_body_placeholder (List.nth !ops i) !body)
    (range_dn (List.length !ops - 1));
  (* lookup probes *)
  List.iter
    (fun pattern ->
      if P.is_lookup pattern then begin
        let t_param =
          match pattern.t with Ds_var n -> n | _ -> "_t"
        in
        match (pattern.e, pattern.a, pattern.v) with
        | Ds_const e_val, Ds_const a_val, Ds_const v_val ->
          let probe_s_var = "?s_probe" in
          let probe_iter_var = S.S_symbol "?it_probe" in
          body := list [
              S.S_keyword "begin";
              list [ S.S_keyword "set!"; S.S_symbol probe_s_var;
                     list [ S.S_keyword "scanner-open"; S.S_str "EAVT" ] ];
              list [ S.S_keyword "set!"; probe_iter_var;
                     list [ S.S_keyword "scanner-iterate-init";
                            S.S_symbol probe_s_var; list [] ] ];
              list [
                S.S_keyword "begin";
                list [ S.S_keyword "scanner-push"; S.S_symbol probe_s_var;
                       bound_to_sexpr e_val ];
                list [ S.S_keyword "scanner-push"; S.S_symbol probe_s_var;
                       bound_to_sexpr a_val ];
                list [ S.S_keyword "scanner-push"; S.S_symbol probe_s_var;
                       bound_to_sexpr v_val ];
                list [
                  S.S_keyword "while";
                  list [ S.S_keyword "set!"; S.S_symbol t_param;
                         list [ S.S_keyword "scanner-iterate-next"; probe_iter_var ] ];
                  list [
                    S.S_keyword "begin";
                    list [ S.S_keyword "scanner-push"; S.S_symbol probe_s_var;
                           S.S_symbol t_param ];
                    !body;
                    list [ S.S_keyword "scanner-pop"; S.S_symbol probe_s_var ];
                  ];
                ];
                list [ S.S_keyword "scanner-pop"; S.S_symbol probe_s_var ];
                list [ S.S_keyword "scanner-pop"; S.S_symbol probe_s_var ];
                list [ S.S_keyword "scanner-pop"; S.S_symbol probe_s_var ];
              ];
            ]
        | _ -> ()
      end)
    plan.Pl.lookups;
  (* scanner bindings prefix *)
  let full_body = ref !body in
  if scanner_bindings <> [] then begin
    let stmts = ref [ S.S_keyword "begin" ] in
    List.iter
      (fun b ->
        match b with
        | S.S_list (name :: [ open_args ]) ->
          stmts := !stmts @ [ list [ S.S_keyword "set!"; name; open_args ] ]
        | _ -> ())
      scanner_bindings;
    stmts := !stmts @ [ !body ];
    full_body := list !stmts
  end;
  flatten_begins !full_body

let build_projection (plan : Pl.query_plan_result) (total_proj_len : int)
    (constant_indices : (int * Pl.plan_value) list) : S.t =
  let proj_args = ref [] in
  let fv_idx = ref 0 in
  let find_vars =
    List.map
      (function
        | Fv_var n -> n
        | Fv_const (n, _) -> n)
      plan.Pl.find_vars
  in
  for i = 0 to total_proj_len - 1 do
    match List.assoc_opt i constant_indices with
    | Some pv ->
      proj_args := !proj_args @ [ plan_value_to_sexpr pv ];
      fv_idx := !fv_idx + 1
    | None ->
      if !fv_idx >= List.length find_vars then
        proj_args := !proj_args @ [ S.S_void ]
      else begin
        let var_name = List.nth find_vars !fv_idx in
        incr fv_idx;
        let bnd = S.S_symbol var_name in
        if List.mem var_name plan.Pl.attr_vars then
          proj_args := !proj_args @ [ list [ S.S_keyword "attr-name"; bnd ] ]
        else
          proj_args := !proj_args @ [ list [ S.S_keyword "resolve-val"; bnd ] ]
      end
  done;
  list ([ S.S_keyword "result-row" ] @ !proj_args)

let compile_select_scheme (plan : Pl.query_plan_result) : Sexpr.t =
  let find_vars = ref [] in
  let constant_indices = ref [] in
  List.iteri
    (fun i fv ->
      match fv with
      | Fv_var n -> find_vars := !find_vars @ [ n ]
      | Fv_const (n, cval) ->
        find_vars := !find_vars @ [ n ];
        (match Pl.from_bound_value cval with
         | Some pv -> constant_indices := !constant_indices @ [ (i, pv) ]
         | None -> ()))
    plan.Pl.find_vars;
  let leaf_body =
    if plan.Pl.exists_mode && !constant_indices = [] then
      list [ S.S_keyword "result-row"; S.S_int 1L ]
    else
      build_projection plan (List.length plan.Pl.find_vars) !constant_indices
  in
  build_triejoin_scheme plan !find_vars leaf_body

(* planner.ml — cost-based join ordering, mirroring nim_planner/planner.nim
   (+ planner_ast.nim types).  The wire output depends on: bestOrdering,
   clauseIndexes, orderedVars (with skip-var insertion), iterPlans and
   syntheticVars — the search must reproduce the Nim tie-breaking and
   cost arithmetic exactly. *)

open Datalog_ast
module P = Pattern
module R = Resolve

(* ── planner_ast types ─────────────────────────────────────────────── *)

type spec_kind =
  | Sk_var of string
  | Sk_bound of int64
  | Sk_bound_attr of int32
  | Sk_bound_value of int64 * float * string  (* int, float, str *)
  | Sk_bound_param of int32

type plan_value =
  | Pv_value of int64 * float * string  (* int, float, str — Nim packs
                                           the three fields in one ref *)
  | Pv_param of int32

let pv_int i = Pv_value (i, 0.0, "")
let pv_float f = Pv_value (0L, f, "")
let pv_str s = Pv_value (0L, 0.0, s)

type depth_trace = {
  dt_var_name : string;
  dt_active_clauses : (int * string) list;
  dt_estimated_elements : float;
  dt_is_blind : bool;
  dt_step_cost : float;
  dt_penalty : bool;
}

type plan_trace = {
  mutable pt_ordering : string list;
  mutable pt_depths : depth_trace list;
  pt_total_cost : float;
  mutable pt_pruned : bool;
  mutable pt_chosen : bool;
}

type synthetic_var = {
  name : string;
  source_var : string;
  pattern_idx : int;
  position : string;
}

type iter_plan_data = {
  index_name : string;
  idx_order : string array;
  specs : spec_kind array;
  bound_ints : (string * plan_value) list;
  var_depths : (int * string) list;
  same_var_constraints : (int * string list) list;
  active_depths : int list;
  global_var_order : string list;
  attr_is_indexed : bool;
}

type query_plan_result = {
  iter_plans : iter_plan_data list;
  lookups : pattern list;
  join_patterns : pattern list;
  mutable ordered_vars : string list;
  e_vars : string list;
  attr_vars : string list;
  t_lookup_vars : string list;
  var_order : string list;
  plan_traces : plan_trace list;
  mutable history : bool;
  mutable exists_mode : bool;
  mutable find_vars : find_var list;
  mutable range_bounds : (string * (string * plan_value) list list) list;
  synthetic_vars : synthetic_var list;
}

(* ── bound-value conversion ────────────────────────────────────────── *)

let from_bound_value (bv : bound_value) : plan_value option =
  match bv with
  | Bv_int i -> Some (pv_int i)
  | Bv_float f -> Some (pv_float f)
  | Bv_str s -> Some (pv_str s)
  | Bv_attr name -> Some (pv_str name)
  | Bv_resolved_attr (id, _, _, _) -> Some (pv_int (Int64.of_int32 id))
  | Bv_param idx -> Some (Pv_param idx)
  | Bv_bool b -> Some (pv_int (if b then 1L else 0L))
  | Bv_missing _ | Bv_var _ -> None

let convert_range_bounds
    (bounds : (string * range_cond list list) list)
  : (string * (string * plan_value) list list) list =
  List.map
    (fun (var_name, branches) ->
      (var_name,
       List.map
         (fun branch ->
           List.filter_map
             (fun (op, bv) ->
               match from_bound_value bv with
               | Some pv -> Some (op, pv)
               | None -> None)
             branch)
         branches))
    bounds

(* ── index selection ───────────────────────────────────────────────── *)

let is_slot_bound (slot : slot) (bound_vars : string list) : bool =
  match slot with
  | Ds_missing -> false
  | Ds_const (Bv_missing _) -> false
  | Ds_const _ -> true
  | Ds_var n -> List.mem n bound_vars

let is_prefix_ok (slot : slot) (bound_vars : string list) : bool =
  match slot with
  | Ds_missing -> true
  | Ds_const _ -> true
  | Ds_var n -> List.mem n bound_vars

let target_pos_of (pattern : pattern) (var_name : string) : string =
  let rec loop = function
    | [] -> ""
    | pos :: rest ->
      if (match slot pattern pos with Ds_var n -> n = var_name | _ -> false)
      then pos
      else loop rest
  in
  loop [ "e"; "a"; "v"; "t"; "added" ]

let find_best_index (pattern : pattern) (var_name : string)
    (bound_vars : string list) (_ref_attrs : string list)
  : string * int * int =
  let target_pos = target_pos_of pattern var_name in
  if target_pos = "" then ("", 0, 0)
  else begin
    let attr_is_ref =
      match pattern.a with
      | Ds_const (Bv_resolved_attr (_, _, is_ref, _)) -> is_ref
      | _ -> false
    in
    let attr_is_indexed =
      match pattern.a with
      | Ds_const (Bv_resolved_attr (_, _, _, is_indexed)) -> is_indexed
      | _ -> true
    in
    let best = ref ("", 0, 0) in
    let best_inited = ref false in
    List.iter
      (fun (idx_name, idx_order) ->
        if not (idx_name = "VAET" && not attr_is_ref)
           && not (idx_name = "AVET" && not attr_is_indexed) then begin
          let pos_in_idx =
            let rec find i =
              if i >= Array.length idx_order then -1
              else if idx_order.(i) = target_pos then i
              else find (i + 1)
            in
            find 0
          in
          if pos_in_idx >= 0 then begin
            let valid =
              let rec all_ok pi =
                pi >= pos_in_idx
                || (is_prefix_ok (slot pattern idx_order.(pi)) bound_vars
                    && all_ok (pi + 1))
              in
              all_ok 0
            in
            if valid then begin
              let rec prefix_len pi =
                if pi >= pos_in_idx then 0
                else if is_slot_bound (slot pattern idx_order.(pi)) bound_vars
                then 1 + prefix_len (pi + 1)
                else 0
              in
              let prefix_len = prefix_len 0 in
              let gap_count =
                let rec count pi =
                  if pi >= pos_in_idx then 0
                  else
                    (match slot pattern idx_order.(pi) with
                     | Ds_missing -> 1
                     | _ -> 0)
                    + count (pi + 1)
                in
                count 0
              in
              let (_, best_pl, best_gc) = !best in
              if not !best_inited || prefix_len > best_pl
                 || (prefix_len = best_pl && gap_count < best_gc) then begin
                best := (idx_name, prefix_len, gap_count);
                best_inited := true
              end
            end
          end
        end)
      P.index_orders;
    if !best_inited then !best else ("", 0, 0)
  end

let is_var_reachable_in_index (pattern : pattern) (var_name : string)
    (index_name : string) (bound_vars : string list) : bool =
  let target_pos = target_pos_of pattern var_name in
  if target_pos = "" then false
  else begin
    let idx_entry = P.index_entry index_name in
    let pos_in_idx =
      let rec find i =
        if i >= Array.length idx_entry then -1
        else if idx_entry.(i) = target_pos then i
        else find (i + 1)
      in
      find 0
    in
    if pos_in_idx < 0 then false
    else begin
      let rec all_bound pi =
        pi >= pos_in_idx
        || (is_slot_bound (slot pattern idx_entry.(pi)) bound_vars
            && all_bound (pi + 1))
      in
      all_bound 0
    end
  end

let estimate_cardinality (stats : R.plan_stats) (pattern_idx : int)
    (index_name : string) (var_name : string) : float =
  match Hashtbl.find_opt stats.R.estimates (pattern_idx, index_name, var_name) with
  | Some f -> f
  | None -> infinity

(* ── the ordering search ───────────────────────────────────────────── *)

type search_state = {
  mutable best_ordering : string list;
  mutable best_clause_indexes : string option array;
  mutable best_cost : float;
  mutable traces : plan_trace list;
}

let var_priority (name : string) : int =
  let starts prefix =
    String.length name >= String.length prefix
    && String.sub name 0 (String.length prefix) = prefix
  in
  if starts "?e_" then 0
  else if starts "?a_" then 1
  else if starts "?v" then 2
  else if starts "_t_" then 3
  else if starts "?added_" then 4
  else 5

let rec explore_ordering_depth
    (remaining_vars : string list) (bound_vars : string list)
    (clause_index_map : string option array) (accumulated_cost : float)
    (top_elements : float) (clauses : pattern list)
    (find_set : string list) (range_vars : string list)
    (total_records : float) (stats : R.plan_stats) (join_indices : int list)
    (ref_attrs : string list) (synthetic_vars : synthetic_var list)
    (state : search_state) (path : string list)
    (depth_traces : depth_trace list) : unit =
  if remaining_vars = [] then begin
    state.traces <-
      { pt_ordering = path; pt_depths = depth_traces;
        pt_total_cost = accumulated_cost; pt_pruned = false; pt_chosen = false }
      :: state.traces;
    if accumulated_cost < state.best_cost then begin
      state.best_cost <- accumulated_cost;
      state.best_ordering <- path;
      state.best_clause_indexes <- Array.copy clause_index_map
    end
  end
  else if accumulated_cost >= state.best_cost then
    state.traces <-
      { pt_ordering = path; pt_depths = depth_traces;
        pt_total_cost = accumulated_cost; pt_pruned = true; pt_chosen = false }
      :: state.traces
  else begin
    let bool_key b = if b then 1 else 0 in
    let candidates =
      List.sort
        (fun a b ->
          let c = compare (bool_key (List.mem b find_set)) (bool_key (List.mem a find_set)) in
          if c <> 0 then c
          else
            let c2 = compare (var_priority a) (var_priority b) in
            if c2 <> 0 then c2 else compare a b)
        remaining_vars
    in
    List.iter
      (fun current_var ->
        (* synthetic vars need their source bound first — skip candidate *)
        let skip =
          match List.find_opt (fun s -> s.name = current_var) synthetic_vars with
          | Some synth -> not (List.mem synth.source_var bound_vars)
          | None -> false
        in
        if not skip then begin
          let active_clauses = ref [] in
          let clause_sizes = ref [] in
          let new_clause_indexes = Array.copy clause_index_map in
          let total_gaps = ref 0 in
          List.iteri
            (fun ci clause ->
              if P.contains_var_in_eav clause current_var then begin
                match clause_index_map.(ci) with
                | Some assigned_idx ->
                  if is_var_reachable_in_index clause current_var assigned_idx bound_vars then begin
                    active_clauses := !active_clauses @ [ (ci, assigned_idx) ];
                    let sz =
                      estimate_cardinality stats (List.nth join_indices ci)
                        assigned_idx current_var
                    in
                    clause_sizes := !clause_sizes @ [ sz ]
                  end
                | None ->
                  let (best_name, _, best_gap) =
                    find_best_index clause current_var bound_vars ref_attrs
                  in
                  if best_name <> "" then begin
                    active_clauses := !active_clauses @ [ (ci, best_name) ];
                    new_clause_indexes.(ci) <- Some best_name;
                    let sz =
                      estimate_cardinality stats (List.nth join_indices ci)
                        best_name current_var
                    in
                    clause_sizes := !clause_sizes @ [ sz ];
                    total_gaps := !total_gaps + best_gap
                  end
              end)
            clauses;
          let is_blind = !active_clauses = [] in
          let range_sel = if List.mem current_var range_vars then 0.1 else 1.0 in
          let depth = List.length path in
          let level_elements, step_cost =
            match List.find_opt (fun s -> s.name = current_var) synthetic_vars with
            | Some _ -> (top_elements, float_of_int depth *. 0.1)
            | None ->
              if is_blind then begin
                let el = total_records *. range_sel in
                if depth = 0 then (el, el *. el)
                else (el, top_elements *. el)
              end else begin
                let el = List.fold_left Float.min infinity !clause_sizes *. range_sel in
                let undef_penalty =
                  List.fold_left
                    (fun acc (ci, _) ->
                      let cl = List.nth clauses ci in
                      let undef_count =
                        List.fold_left
                          (fun acc s ->
                            match s with
                            | Ds_var n when n <> current_var
                                           && not (List.mem n bound_vars) -> acc + 1
                            | _ -> acc)
                          0
                          [ cl.e; cl.a; cl.v ]
                      in
                      if undef_count > 0 then
                        Float.max acc (1.0 +. float_of_int undef_count)
                      else acc)
                    1.0
                    !active_clauses
                in
                let cost =
                  el *. float_of_int (List.length !active_clauses)
                  *. undef_penalty *. (1.0 +. float_of_int !total_gaps)
                in
                (el, cost)
              end
          in
          let adjusted_cost = step_cost in
          let path = path @ [ current_var ] in
          let depth_traces =
            depth_traces
            @ [ { dt_var_name = current_var;
                  dt_active_clauses = !active_clauses;
                  dt_estimated_elements = level_elements;
                  dt_is_blind = is_blind;
                  dt_step_cost = adjusted_cost;
                  dt_penalty = false } ]
          in
          let new_bound = bound_vars @ [ current_var ] in
          let new_remaining = List.filter (fun v -> v <> current_var) remaining_vars in
          explore_ordering_depth new_remaining new_bound new_clause_indexes
            (accumulated_cost +. adjusted_cost) level_elements clauses
            find_set range_vars total_records stats join_indices ref_attrs
            synthetic_vars state path depth_traces
        end)
      candidates
  end

(* ── iter plans ────────────────────────────────────────────────────── *)


let firstn (n : int) (l : string list) : string list =
  let rec loop i acc = function
    | [] -> List.rev acc
    | x :: rest -> if i >= n then List.rev acc else loop (i + 1) (x :: acc) rest
  in
  loop 0 [] l

let bound_positions_before (ip : iter_plan_data) (depth : int)
  : (string * plan_value) list =
  let cutoff =
    let find (d, p) =
      if d = depth then
        let rec idx i =
          if i >= Array.length ip.idx_order then Array.length ip.idx_order
          else if ip.idx_order.(i) = p then i
          else idx (i + 1)
        in
        idx 0
      else -1
    in
    let rec loop = function
      | [] -> Array.length ip.idx_order
      | dp :: rest ->
        let c = find dp in
        if c >= 0 then c else loop rest
    in
    loop ip.var_depths
  in
  let rec collect i acc =
    if i >= cutoff then List.rev acc
    else begin
      let pos = ip.idx_order.(i) in
      if pos = "added" then collect (i + 1) acc
      else
        match List.assoc_opt pos ip.bound_ints with
        | Some pv -> collect (i + 1) ((pos, pv) :: acc)
        | None -> collect (i + 1) acc
    end
  in
  collect 0 []

let all_bound_positions (ip : iter_plan_data) : (string * plan_value) list =
  List.filter_map
    (fun pos ->
      if pos = "added" then None
      else
        match List.assoc_opt pos ip.bound_ints with
        | Some pv -> Some (pos, pv)
        | None -> None)
    (Array.to_list ip.idx_order)

(* ── buildQueryPlan ────────────────────────────────────────────────── *)

let build_iter_plan (pattern : pattern) (pattern_idx : int) (idx_name : string)
    (bound_ints : (string * plan_value) list) (global_var_order : string list)
    (synthetic_vars : synthetic_var list) : iter_plan_data =
  let idx_entry = P.index_entry idx_name in
  let idx_order = Array.copy idx_entry in
  let synth_name_for (pos : string) : string =
    match
      List.find_opt
        (fun s -> s.pattern_idx = pattern_idx && s.position = pos)
        synthetic_vars
    with
    | Some s -> s.name
    | None -> ""
  in
  let slots = [| pattern.e; pattern.a; pattern.v; pattern.t; pattern.added |] in
  let specs = Array.make 5 (Sk_bound 0L) in
  Array.iteri
    (fun i s ->
      specs.(i) <-
        match s with
        | Ds_missing -> Sk_bound 0L
        | Ds_var n -> Sk_var n
        | Ds_const bv ->
          (match bv with
           | Bv_int i -> Sk_bound_value (i, 0.0, "")
           | Bv_float f -> Sk_bound_value (0L, f, "")
           | Bv_str s -> Sk_bound_value (0L, 0.0, s)
           | Bv_attr name -> Sk_bound_value (0L, 0.0, name)
           | Bv_resolved_attr (id, _, _, _) -> Sk_bound_attr id
           | Bv_param idx -> Sk_bound_param idx
           | Bv_var n -> Sk_var n
           | Bv_missing _ | Bv_bool _ -> Sk_bound 0L))
    slots;
  let var_depths = ref [] in
  let same_var_constraints = ref [] in
  let active_depths_set = ref [] in
  let seen_real_var = ref false in
  Array.iter
    (fun pos ->
      let spec_idx =
        match pos with
        | "e" -> 0 | "a" -> 1 | "v" -> 2 | "t" -> 3 | "added" -> 4
        | _ -> -1
      in
      if spec_idx >= 0 then begin
        let sl = slot pattern pos in
        match sl with
        | Ds_var var_name ->
          seen_real_var := true;
          let synthetic_name = synth_name_for pos in
          let effective_name =
            if synthetic_name <> "" then synthetic_name else var_name
          in
          let found_depth =
            let rec find i = function
              | [] -> -1
              | v :: rest -> if v = effective_name then i else find (i + 1) rest
            in
            find 0 global_var_order
          in
          if found_depth >= 0 then begin
            if not (List.mem found_depth !active_depths_set) then begin
              var_depths := !var_depths @ [ (found_depth, pos) ];
              active_depths_set := !active_depths_set @ [ found_depth ];
              if effective_name <> var_name then
                specs.(spec_idx) <- Sk_var effective_name
            end else begin
              let existing =
                match List.assoc_opt found_depth !same_var_constraints with
                | Some l -> l
                | None -> []
              in
              same_var_constraints :=
                (found_depth, existing @ [ pos ])
                :: List.remove_assoc found_depth !same_var_constraints
            end
          end
        | Ds_missing ->
          if not !seen_real_var then begin
            let synth_name =
              "?skip_" ^ pos ^ "_" ^ String.lowercase_ascii idx_entry.(0)
            in
            let found_depth =
              let rec find i = function
                | [] -> -1
                | v :: rest -> if v = synth_name then i else find (i + 1) rest
              in
              find 0 global_var_order
            in
            if found_depth >= 0 && not (List.mem found_depth !active_depths_set) then begin
              var_depths := !var_depths @ [ (found_depth, pos) ];
              active_depths_set := !active_depths_set @ [ found_depth ];
              specs.(spec_idx) <- Sk_var synth_name
            end
          end
        | Ds_const _ -> ()
      end)
    idx_entry;
  let active_depths = ref (List.sort compare !active_depths_set) in
  let var_depths_sorted =
    List.sort (fun (a, _) (b, _) -> compare a b) !var_depths
  in
  (* filter varDepths: remove unreachable entries *)
  let filtered =
    List.filter
      (fun (depth, pos) ->
        let sl = slot pattern pos in
        match sl with
        | Ds_var _ ->
          let resolved = firstn depth global_var_order in
          let idx_entry2 = P.index_entry idx_name in
          let pos_in_idx =
            let rec find i =
              if i >= Array.length idx_entry2 then -1
              else if idx_entry2.(i) = pos then i
              else find (i + 1)
            in
            find 0
          in
          if pos_in_idx < 0 then false
          else begin
            let rec all_ok pi =
              pi >= pos_in_idx
              || (is_prefix_ok (slot pattern idx_entry2.(pi)) resolved
                  && all_ok (pi + 1))
            in
            all_ok 0
          end
        | _ -> true)
      var_depths_sorted
  in
  let active_depths2 =
    List.fold_left
      (fun acc (d, _) ->
        match acc with
        | last :: _ when last = d -> acc
        | _ -> acc @ [ d ])
      []
      filtered
  in
  ignore !active_depths;
  let attr_is_indexed =
    match pattern.a with
    | Ds_const (Bv_resolved_attr (_, _, _, is_indexed)) -> is_indexed
    | _ -> true
  in
  { index_name = idx_name;
    idx_order;
    specs;
    bound_ints;
    var_depths = filtered;
    same_var_constraints = List.rev !same_var_constraints;
    active_depths = active_depths2;
    global_var_order;
    attr_is_indexed }


(* list_insert: Nim seq.insert(item, i) — insert before index i *)
let list_insert (l : string list) (i : int) (item : string) : string list =
  let rec loop n = function
    | [] -> [ item ]
    | x :: rest -> if n = i then item :: x :: rest else x :: loop (n + 1) rest
  in
  loop 0 l

let build_query_plan (where_patterns : pattern list) (find_vars : string list)
    (range_vars : string list) (stats : R.plan_stats) : query_plan_result =
  let lookups = List.filter P.is_lookup where_patterns in
  let join_indices =
    List.fold_left
      (fun acc (i, p) -> if not (P.is_lookup p) then acc @ [ i ] else acc)
      []
      (List.mapi (fun i p -> (i, p)) where_patterns)
  in
  let join_patterns = List.filter (fun p -> not (P.is_lookup p)) where_patterns in
  if join_patterns = [] then begin
    let t_lookup_vars =
      List.fold_left
        (fun acc p ->
          match p.t with
          | Ds_var n when not (List.mem n acc) -> acc @ [ n ]
          | _ -> acc)
        [] lookups
    in
    { iter_plans = []; lookups; join_patterns; ordered_vars = [];
      e_vars = []; attr_vars = []; t_lookup_vars; var_order = [];
      plan_traces = []; history = false; exists_mode = false;
      find_vars = []; range_bounds = []; synthetic_vars = [] }
  end else begin
    let seen = ref [] in
    let var_order = ref [] in
    let all_vars = ref [] in
    let synthetic_vars = ref [] in
    List.iteri
      (fun pat_idx pattern ->
        let seen_in_pattern = ref [] in
        let occurrences = Hashtbl.create 8 in
        List.iter
          (fun (pos_name, sl) ->
            match sl with
            | Ds_var name ->
              let occ =
                match Hashtbl.find_opt occurrences name with
                | Some l -> l
                | None -> []
              in
              Hashtbl.replace occurrences name (occ @ [ pos_name ]);
              if List.length occ + 1 > 2 then
                raise (Failure
                         ("variable '" ^ name ^ "' appears in more than 2 positions in pattern "
                          ^ string_of_int pat_idx ^
                          "; only 2 occurrences (same-var confirmation) are supported"));
              if not (List.mem name !seen) then begin
                seen := name :: !seen;
                var_order := !var_order @ [ name ];
                all_vars := !all_vars @ [ name ];
                seen_in_pattern := name :: !seen_in_pattern
              end
              else if not (List.mem name !seen_in_pattern) then
                seen_in_pattern := name :: !seen_in_pattern
              else begin
                let synth_name =
                  name ^ "@p" ^ string_of_int pat_idx ^ "." ^ pos_name
                in
                all_vars := !all_vars @ [ synth_name ];
                synthetic_vars :=
                  !synthetic_vars
                  @ [ { name = synth_name; source_var = name;
                        pattern_idx = pat_idx; position = pos_name } ]
              end
            | _ -> ())
          [ ("e", pattern.e); ("a", pattern.a); ("v", pattern.v);
            ("t", pattern.t); ("added", pattern.added) ])
      join_patterns;
    let e_vars =
      List.filter_map (fun p -> match p.e with Ds_var n -> Some n | _ -> None)
        join_patterns
      |> List.sort_uniq compare
    in
    let attr_vars =
      List.filter_map (fun p -> match p.a with Ds_var n -> Some n | _ -> None)
        join_patterns
      |> List.sort_uniq compare
    in
    let find_set = List.sort_uniq compare find_vars in
    let total_records = stats.R.total_eavt in
    let ref_attrs =
      List.filter_map
        (fun p ->
          match p.a with
          | Ds_const (Bv_resolved_attr (_, name, is_ref, _)) when is_ref -> Some name
          | _ -> None)
        join_patterns
      |> List.sort_uniq compare
    in
    let clause_index_map = Array.make (List.length join_patterns) None in
    let state =
      { best_ordering = []; best_clause_indexes = [||]; best_cost = infinity;
        traces = [] }
    in
    explore_ordering_depth !all_vars [] clause_index_map 0.0 1.0 join_patterns
      find_set range_vars total_records stats join_indices ref_attrs
      !synthetic_vars state [] [];
    let best_ordering_orig = state.best_ordering in
    let ordered_vars =
      if state.best_ordering <> [] then state.best_ordering else !all_vars
    in
    let clause_indexes =
      if Array.length state.best_clause_indexes > 0 then
        state.best_clause_indexes
      else clause_index_map
    in
    (* validation-only patterns *)
    List.iteri
      (fun pat_idx pattern ->
        if clause_indexes.(pat_idx) = None then begin
          let has_var =
            List.exists
              (fun s -> match s with Ds_var _ -> true | _ -> false)
              [ pattern.e; pattern.a; pattern.v; pattern.t; pattern.added ]
          in
          if (not has_var) && not (P.is_lookup pattern) then begin
            let best_idx = ref "" in
            let best_score = ref 0 in
            List.iter
              (fun (idx_name, idx_order) ->
                let rec score i acc =
                  if i >= Array.length idx_order then acc
                  else
                    match slot pattern idx_order.(i) with
                    | Ds_const _ -> score (i + 1) (acc + 1)
                    | _ -> acc
                in
                let s = score 0 0 in
                if s > !best_score then begin
                  best_score := s;
                  best_idx := idx_name
                end)
              P.index_orders;
            if !best_score > 0 then clause_indexes.(pat_idx) <- Some !best_idx
          end
        end)
      join_patterns;
    (* pre-compute skip vars for Missing gaps *)
    let ordered_vars = ref ordered_vars in

    (* (rewritten below — see loop) *)
    List.iteri
      (fun pat_idx pattern ->
        match clause_indexes.(pat_idx) with
        | None -> ()
        | Some idx_name ->
          let idx_entry = P.index_entry idx_name in
          let first_var_pos =
            let rec find i =
              if i >= Array.length idx_entry then -1
              else
                match slot pattern idx_entry.(i) with
                | Ds_var _ -> i
                | _ -> find (i + 1)
            in
            find 0
          in
          if first_var_pos >= 0 then begin
            let target_var =
              match slot pattern idx_entry.(first_var_pos) with
              | Ds_var n -> n
              | _ -> ""
            in
            for pos_idx = 0 to first_var_pos - 1 do
              let pos = idx_entry.(pos_idx) in
              match slot pattern pos with
              | Ds_missing ->
                let synth_name =
                  "?skip_" ^ pos ^ "_" ^ String.lowercase_ascii idx_name
                in
                if not (List.mem synth_name !ordered_vars) then begin
                  let found =
                    let rec insert_before vi =
                      vi >= List.length !ordered_vars
                      || (match List.nth !ordered_vars vi with
                          | v when v = target_var ->
                            ordered_vars :=
                              list_insert !ordered_vars vi synth_name;
                            true
                          | _ -> insert_before (vi + 1))
                    in
                    insert_before 0
                  in
                  if not found then ordered_vars := !ordered_vars @ [ synth_name ]
                end
              | _ -> ()
            done
          end)
      join_patterns;
    let iter_plans = ref [] in
    List.iteri
      (fun pat_idx pattern ->
        match clause_indexes.(pat_idx) with
        | None -> ()
        | Some idx_name ->
          let bound_ints = ref [] in
          (match pattern.e with
           | Ds_const bv ->
             (match bv with
              | Bv_int i -> bound_ints := !bound_ints @ [ ("e", pv_int i) ]
              | Bv_str s -> bound_ints := !bound_ints @ [ ("e", pv_str s) ]
              | Bv_attr n -> bound_ints := !bound_ints @ [ ("e", pv_str n) ]
              | Bv_param p -> bound_ints := !bound_ints @ [ ("e", Pv_param p) ]
              | _ -> ())
           | _ -> ());
          (match pattern.a with
           | Ds_const bv ->
             (match bv with
              | Bv_resolved_attr (_, name, _, _) ->
                bound_ints := !bound_ints @ [ ("a", pv_str name) ]
              | Bv_str s -> bound_ints := !bound_ints @ [ ("a", pv_str s) ]
              | Bv_attr n -> bound_ints := !bound_ints @ [ ("a", pv_str n) ]
              | Bv_param p -> bound_ints := !bound_ints @ [ ("a", Pv_param p) ]
              | _ -> ())
           | _ -> ());
          (match pattern.v with
           | Ds_const bv ->
             (match bv with
              | Bv_int i -> bound_ints := !bound_ints @ [ ("v", pv_int i) ]
              | Bv_float f -> bound_ints := !bound_ints @ [ ("v", pv_float f) ]
              | Bv_str s -> bound_ints := !bound_ints @ [ ("v", pv_str s) ]
              | Bv_attr n -> bound_ints := !bound_ints @ [ ("v", pv_str n) ]
              | Bv_param p -> bound_ints := !bound_ints @ [ ("v", Pv_param p) ]
              | _ -> ())
           | _ -> ());
          iter_plans :=
            !iter_plans
            @ [ build_iter_plan pattern pat_idx idx_name !bound_ints
                  !ordered_vars !synthetic_vars ])
      join_patterns;
    let t_lookup_vars =
      List.fold_left
        (fun acc p ->
          match p.t with
          | Ds_var n when not (List.mem n acc) -> acc @ [ n ]
          | _ -> acc)
        [] lookups
    in
    let plan_traces =
      List.map
        (fun trace ->
          if trace.pt_pruned then trace
          else if best_ordering_orig = trace.pt_ordering then begin
            trace.pt_chosen <- true;
            let old_depths = Hashtbl.create 16 in
            List.iter
              (fun d -> Hashtbl.replace old_depths d.dt_var_name d)
              trace.pt_depths;
            let new_depths =
              List.map
                (fun var_name ->
                  match Hashtbl.find_opt old_depths var_name with
                  | Some d -> d
                  | None ->
                    { dt_var_name = var_name; dt_active_clauses = [];
                      dt_estimated_elements = 0.0; dt_is_blind = false;
                      dt_step_cost = 0.0; dt_penalty = false })
                !ordered_vars
            in
            trace.pt_depths <- new_depths;
            trace.pt_ordering <- !ordered_vars;
            trace
          end else trace)
        state.traces
    in
    { iter_plans = !iter_plans; lookups; join_patterns;
      ordered_vars = !ordered_vars; e_vars; attr_vars; t_lookup_vars;
      var_order = !var_order; plan_traces; history = false;
      exists_mode = false; find_vars = []; range_bounds = [];
      synthetic_vars = !synthetic_vars }
  end


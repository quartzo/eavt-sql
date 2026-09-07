(* compile_stats.ml — CompileStats + msgpack decode, mirroring
   nim_datalog/stats.nim (packStats/statsFromMsgpack format): a map of
   five keys; attrIds/partitionIds values are uint64, indexEstimates
   float64, ref/indexedAttrs string arrays. *)

type t = {
  attr_ids : (string * int32) list;
  index_estimates : (string * float) list;
  partition_ids : (string * int64) list;
  ref_attrs : string list;
  indexed_attrs : string list;
}

let empty = { attr_ids = []; index_estimates = []; partition_ids = [];
              ref_attrs = []; indexed_attrs = [] }

let attr_id (s : t) (name : string) : int32 option =
  match List.assoc_opt name s.attr_ids with
  | Some v -> Some v
  | None -> None

let is_ref (s : t) (name : string) : bool = List.mem name s.ref_attrs
let is_indexed (s : t) (name : string) : bool = List.mem name s.indexed_attrs

let get_str (kvs : (Msgpack.t * Msgpack.t) list) (key : string) : Msgpack.t option =
  Msgpack.member (Msgpack.Str key) kvs

let decode (m : Msgpack.t) : t =
  match m with
  | Msgpack.Map kvs ->
    let attr_ids =
      match get_str kvs "attrIds" with
      | Some (Msgpack.Map ps) ->
        List.filter_map
          (fun (k, v) ->
            match (k, v) with
            | Msgpack.Str name, Msgpack.Int id -> Some (name, Int64.to_int32 id)
            | _ -> None)
          ps
      | _ -> []
    in
    let index_estimates =
      match get_str kvs "indexEstimates" with
      | Some (Msgpack.Map ps) ->
        List.filter_map
          (fun (k, v) ->
            match (k, v) with
            | Msgpack.Str name, Msgpack.Float f -> Some (name, f)
            | _ -> None)
          ps
      | _ -> []
    in
    let partition_ids =
      match get_str kvs "partitionIds" with
      | Some (Msgpack.Map ps) ->
        List.filter_map
          (fun (k, v) ->
            match (k, v) with
            | Msgpack.Str name, Msgpack.Int id -> Some (name, id)
            | _ -> None)
          ps
      | _ -> []
    in
    let str_list key =
      match get_str kvs key with
      | Some (Msgpack.Array xs) ->
        List.filter_map (function Msgpack.Str s -> Some s | _ -> None) xs
      | _ -> []
    in
    { attr_ids; index_estimates; partition_ids;
      ref_attrs = str_list "refAttrs"; indexed_attrs = str_list "indexedAttrs" }
  | _ -> empty

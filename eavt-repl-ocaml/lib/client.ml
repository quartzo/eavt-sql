(* client.ml — UDS client for the eavt query server: 4-byte BE length
   framing over MessagePack, mirroring eavt_transactor_nim/client.nim.
   Streaming responses ({"rows": [...], "more": bool}) collect into
   chunks; row values convert to display strings exactly like the Nim
   REPL's parseValue path. *)

exception Server_disconnected of string
exception Server_error of string

type t = { sock_path : string; mutable fd : Unix.file_descr option }

let default_socket ~query () =
  let name = if query then "eavt-query.sock" else "eavt-transactor.sock" in
  match Sys.getenv_opt "XDG_RUNTIME_DIR" with
  | Some xdg when xdg <> "" -> Filename.concat (Filename.concat xdg "eavt") name
  | _ ->
    let home = Unix.getenv "HOME" in
    Filename.concat
      (Filename.concat (Filename.concat (Filename.concat home ".local") "state") "eavt")
      name

let socket_path () = default_socket ~query:true ()

let connect sock_path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (match Unix.connect fd (Unix.ADDR_UNIX sock_path) with
   | () -> { sock_path; fd = Some fd }
   | exception e ->
     Unix.close fd;
     raise e)

let try_connect sock_path = try Some (connect sock_path) with _ -> None

let close t =
  (match t.fd with Some fd -> (try Unix.close fd with _ -> ()) | None -> ());
  t.fd <- None

let with_fd t f =
  match t.fd with
  | Some fd -> f fd
  | None -> raise (Server_disconnected "server disconnected (closed)")

(* ── framing ───────────────────────────────────────────────────────── *)

let write_all fd (buf : Bytes.t) off len =
  let rec loop sent =
    if sent >= len then ()
    else
      let n = Unix.write fd buf (off + sent) (len - sent) in
      if n <= 0 then raise (Server_disconnected "server disconnected (send)")
      else loop (sent + n)
  in
  loop 0

let read_all fd (buf : Bytes.t) off len =
  let rec loop got =
    if got >= len then ()
    else
      let n = Unix.read fd buf (off + got) (len - got) in
      if n <= 0 then raise (Server_disconnected "server disconnected (read body)")
      else loop (got + n)
  in
  loop 0

let send_frame t (body : Bytes.t) =
  with_fd t (fun fd ->
      let len = Bytes.length body in
      let hdr = Bytes.create 4 in
      Bytes.set hdr 0 (Char.chr ((len lsr 24) land 0xff));
      Bytes.set hdr 1 (Char.chr ((len lsr 16) land 0xff));
      Bytes.set hdr 2 (Char.chr ((len lsr 8) land 0xff));
      Bytes.set hdr 3 (Char.chr (len land 0xff));
      write_all fd hdr 0 4;
      if len > 0 then write_all fd body 0 len)

let recv_frame t : Bytes.t =
  with_fd t (fun fd ->
      let hdr = Bytes.create 4 in
      read_all fd hdr 0 4;
      let b0 = Char.code (Bytes.get hdr 0) in
      let b1 = Char.code (Bytes.get hdr 1) in
      let b2 = Char.code (Bytes.get hdr 2) in
      let b3 = Char.code (Bytes.get hdr 3) in
      let len = (b0 lsl 24) lor (b1 lsl 16) lor (b2 lsl 8) lor b3 in
      if len <= 0 then raise (Server_disconnected "server disconnected (recv)");
      if len > 100_000_000 then
        raise (Server_disconnected "server disconnected (oversize frame)");
      let body = Bytes.create len in
      read_all fd body 0 len;
      body)

(* ── request/response encoding ─────────────────────────────────────── *)

let req ty fields = Msgpack.Map ((Msgpack.Str "type", Msgpack.Str ty) :: fields)

let send_request t m =
  let buf = Buffer.create 256 in
  Msgpack.encode buf m;
  send_frame t (Buffer.to_bytes buf)

let response_error = function
  | Msgpack.Map kvs ->
    (match Msgpack.member (Msgpack.Str "error") kvs with
     | Some (Msgpack.Str s) when s <> "" -> Some s
     | _ -> None)
  | _ -> None

let float_str f =
  let rec loop p =
    if p >= 17 then Printf.sprintf "%.17g" f
    else
      let s = Printf.sprintf "%.*g" p f in
      if float_of_string s = f then s else loop (p + 1)
  in
  let s = if Float.is_nan f then "nan" else loop 1 in
  if
    not
      (String.contains s '.' || String.contains s 'e' || String.contains s 'E'
     || String.contains s 'n' || String.contains s 'i')
  then s ^ ".0"
  else s

let b64 (s : string) : string =
  let digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let buf = Buffer.create ((n + 2) / 3 * 4) in
  let i = ref 0 in
  while !i + 2 < n do
    let x = Char.code s.[!i] lsl 16 lor Char.code s.[!i + 1] lsl 8 lor Char.code s.[!i + 2] in
    Buffer.add_char buf digits.[(x lsr 18) land 63];
    Buffer.add_char buf digits.[(x lsr 12) land 63];
    Buffer.add_char buf digits.[(x lsr 6) land 63];
    Buffer.add_char buf digits.[x land 63];
    i := !i + 3
  done;
  (match n - !i with
   | 1 ->
     let x = Char.code s.[!i] lsl 16 in
     Buffer.add_char buf digits.[(x lsr 18) land 63];
     Buffer.add_char buf digits.[(x lsr 12) land 63];
     Buffer.add_string buf "=="
   | 2 ->
     let x = Char.code s.[!i] lsl 16 lor Char.code s.[!i + 1] lsl 8 in
     Buffer.add_char buf digits.[(x lsr 18) land 63];
     Buffer.add_char buf digits.[(x lsr 12) land 63];
     Buffer.add_char buf digits.[(x lsr 6) land 63];
     Buffer.add_char buf '=';
   | _ -> ());
  Buffer.contents buf

(* Bin renders like msgpack2json's wrapper — what client.nim's $v prints
   after toJsonNode turns msgpack bin into a JSON object. *)
let bin_str b =
  let s = Bytes.to_string b in
  Printf.sprintf {|{"type":"bin","len":%d,"data":"%s"}|} (Bytes.length b) (b64 s)

let rec value_str (v : Msgpack.t) : string =
  match v with
  | Msgpack.Str s -> s
  | Msgpack.Bin b -> bin_str b
  | Msgpack.Int i -> Int64.to_string i
  | Msgpack.Float f -> float_str f
  | Msgpack.Bool true -> "true"
  | Msgpack.Bool false -> "false"
  | Msgpack.Nil -> "null"
  | Msgpack.Array xs ->
    (* array of ints = raw bytes (matches client.nim's JArray path);
       anything else renders as a JSON array, like $ of JArray *)
    if
      List.for_all (function Msgpack.Int _ -> true | _ -> false) xs
      && xs <> []
    then
      String.of_seq
        (List.to_seq
           (List.map (function Msgpack.Int i -> Char.chr (Int64.to_int i land 0xff) | _ -> '\x00') xs))
    else
      let json_scalar v =
        match v with
        | Msgpack.Str s -> Printf.sprintf "%S" s
        | other -> value_str other
      in
      "[" ^ String.concat "," (List.map json_scalar xs) ^ "]"
  | Msgpack.Ext _ | Msgpack.Map _ -> "null"

type chunk = { columns : string list; rows : string list list }

let decode_chunk m : chunk =
  match m with
  | Msgpack.Map kvs ->
    let columns =
      match Msgpack.member (Msgpack.Str "columns") kvs with
      | Some (Msgpack.Array cols) ->
        List.map (function Msgpack.Str s -> s | v -> value_str v) cols
      | _ -> []
    in
    let rows =
      match Msgpack.member (Msgpack.Str "rows") kvs with
      | Some (Msgpack.Array rows) ->
        List.map
          (function
            | Msgpack.Array row -> List.map value_str row
            | v -> [ value_str v ])
          rows
      | _ -> []
    in
    { columns; rows }
  | _ -> { columns = []; rows = [] }

let response_more m =
  match m with
  | Msgpack.Map kvs ->
    (match Msgpack.member (Msgpack.Str "more") kvs with
     | Some (Msgpack.Bool b) -> b
     | _ -> false)
  | _ -> false

let collect_stream t m : chunk list =
  send_request t m;
  let rec loop acc =
    let body = recv_frame t in
    let resp = Msgpack.decode body in
    match response_error resp with
    | Some e -> raise (Server_error e)
    | None ->
      let chunk = decode_chunk resp in
      if response_more resp then loop (chunk :: acc) else List.rev (chunk :: acc)
  in
  loop []

let datalog t query = collect_stream t (req "datalog" [ (Msgpack.Str "query", Msgpack.Str query) ])

let dump t index =
  collect_stream t (req "admin" [ (Msgpack.Str "command", Msgpack.Str ("dump " ^ index)) ])

let kv_scan t cf =
  collect_stream t (req "kv" [ (Msgpack.Str "op", Msgpack.Str "scan"); (Msgpack.Str "cf", Msgpack.Int (Int64.of_int cf)) ])

let admin t command : string =
  send_request t (req "admin" [ (Msgpack.Str "command", Msgpack.Str command) ]);
  let resp = Msgpack.decode (recv_frame t) in
  match resp with
  | Msgpack.Map kvs ->
    (match Msgpack.member (Msgpack.Str "output") kvs with
     | Some (Msgpack.Str s) -> s
     | _ -> "")
  | _ -> ""

let kv_op t op cf key value : string =
  let fields =
    [ (Msgpack.Str "op", Msgpack.Str op);
      (Msgpack.Str "cf", Msgpack.Int (Int64.of_int cf)) ]
    @ (match key with Some k -> [ (Msgpack.Str "key", Msgpack.Str k) ] | None -> [])
    @ (match value with Some v -> [ (Msgpack.Str "value", Msgpack.Str v) ] | None -> [])
  in
  send_request t (req "kv" fields);
  let resp = Msgpack.decode (recv_frame t) in
  match response_error resp with
  | Some e -> "error: " ^ e
  | None -> "ok"

let kv_put t cf key value = kv_op t "put" cf (Some key) (Some value)
let kv_delete t cf key = kv_op t "delete" cf (Some key) None

let kv_get t cf key : string =
  send_request t (req "kv" [ (Msgpack.Str "op", Msgpack.Str "get"); (Msgpack.Str "cf", Msgpack.Int (Int64.of_int cf)); (Msgpack.Str "key", Msgpack.Str key) ]);
  let resp = Msgpack.decode (recv_frame t) in
  match response_error resp with
  | Some e -> "error: " ^ e
  | None -> (
    match resp with
    | Msgpack.Map kvs -> (
      match Msgpack.member (Msgpack.Str "rows") kvs with
      | Some (Msgpack.Array ((Msgpack.Array (cell :: _)) :: _)) -> value_str cell
      | _ -> "(none)")
    | _ -> "(none)")

(* ── tx ────────────────────────────────────────────────────────────── *)

let rec sexpr_wire (v : Edn.t) : Msgpack.t =
  match v with
  | Edn.Int i -> Msgpack.Int i
  | Edn.Float f -> Msgpack.Float f
  | Edn.Str s -> Msgpack.Str s
  | Edn.Bool b -> Msgpack.Bool b
  | Edn.Nil -> Msgpack.Nil
  | Edn.Keyword k -> Msgpack.Ext (Msgpack.ext_keyword, Bytes.of_string k)
  | Edn.Symbol s -> Msgpack.Ext (Msgpack.ext_symbol, Bytes.of_string s)
  | Edn.List xs -> Msgpack.Array (List.map sexpr_wire xs)

let tx t (ops : Edn.t list) : string =
  send_request t
    (req "tx" [ (Msgpack.Str "txdata", Msgpack.Array (List.map sexpr_wire ops)) ]);
  let resp = Msgpack.decode (recv_frame t) in
  match response_error resp with
  | Some e -> "error: " ^ e
  | None -> (
    match resp with
    | Msgpack.Map kvs ->
      let tx_id =
        match Msgpack.member (Msgpack.Str "tx") kvs with
        | Some (Msgpack.Int i) -> Int64.to_string i
        | _ -> "0"
      in
      let parts =
        [ "tx=" ^ tx_id ]
        @ (if Msgpack.member (Msgpack.Str "tempids") kvs <> None then [ "tempids resolved" ] else [])
      in
      "tx-report: " ^ String.concat ", " parts
    | _ -> "error: malformed tx-report")

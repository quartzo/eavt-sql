(* front.ml — OCaml front for the query server (Fase 3 of the
   two-layer split): owns the client socket, compiles Datalog EDN
   locally (byte-identical to the Nim compiler — Fase 2 golden gate)
   and drives the Nim back's internal executor socket for local
   execution.  tx/admin/kv/scheme are forwarded verbatim; responses
   stream through untouched.

   Threading: thread per connection (I/O-bound proxy); the CompileStats
   cache is shared under a mutex. *)

open Eavt_lib

exception Back_error of string

(* ── frame I/O (4-byte BE length + msgpack body) ───────────────────── *)

let read_exact fd buf off len =
  let rec loop got =
    if got >= len then ()
    else
      let n = Unix.read fd buf (off + got) (len - got) in
      if n <= 0 then raise (Back_error "read: closed")
      else loop (got + n)
  in
  loop 0

let read_frame fd : Bytes.t =
  let hdr = Bytes.create 4 in
  read_exact fd hdr 0 4;
  let b i = Char.code (Bytes.get hdr i) in
  let len = (b 0 lsl 24) lor (b 1 lsl 16) lor (b 2 lsl 8) lor b 3 in
  if len <= 0 || len > 100_000_000 then raise (Back_error "bad frame length");
  let body = Bytes.create len in
  read_exact fd body 0 len;
  body

let write_frame fd (body : Bytes.t) : unit =
  let len = Bytes.length body in
  let hdr = Bytes.create 4 in
  Bytes.set hdr 0 (Char.chr ((len lsr 24) land 0xff));
  Bytes.set hdr 1 (Char.chr ((len lsr 16) land 0xff));
  Bytes.set hdr 2 (Char.chr ((len lsr 8) land 0xff));
  Bytes.set hdr 3 (Char.chr (len land 0xff));
  let rec loop (buf : Bytes.t) off remaining =
    if remaining > 0 then begin
      let n = Unix.write fd buf off remaining in
      if n <= 0 then raise (Back_error "write: closed");
      loop buf (off + n) (remaining - n)
    end
  in
  loop hdr 0 4;
  loop body 0 len

let frame_of_msgpack (m : Msgpack.t) : Bytes.t =
  let buf = Buffer.create 256 in
  Msgpack.encode buf m;
  Buffer.to_bytes buf

let error_frame (msg : string) : Bytes.t =
  frame_of_msgpack
    (Msgpack.Map [ (Msgpack.Str "error", Msgpack.Str msg);
                   (Msgpack.Str "more", Msgpack.Bool false) ])

(* ── state: back path + CompileStats cache (TTL 30s, mutex) ────────── *)

let ttl = 30.0

type state = {
  back_path : string;
  mutex : Mutex.t;
  mutable stats : Compile_stats.t option;
  mutable stats_at : float;
}

let make_state back_path =
  { back_path; mutex = Mutex.create (); stats = None; stats_at = 0.0 }

let with_back_conn st (f : Unix.file_descr -> 'a) : 'a =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (match Unix.connect fd (Unix.ADDR_UNIX st.back_path) with
   | () -> ()
   | exception e -> Unix.close fd; raise e);
  Fun.protect ~finally:(fun () -> try Unix.close fd with _ -> ()) (fun () -> f fd)

let request_one st (m : Msgpack.t) : Msgpack.t =
  (* one request → one response frame (admin/schema/tx/kv) *)
  with_back_conn st (fun fd ->
      write_frame fd (frame_of_msgpack m);
      Msgpack.decode (read_frame fd))

(* stats are nested under the "schema" key of the response frame *)
let extract_stats (resp : Msgpack.t) : Compile_stats.t =
  match resp with
  | Msgpack.Map kvs ->
    (match Msgpack.member (Msgpack.Str "schema") kvs with
     | Some nested -> Compile_stats.decode nested
     | None -> raise (Back_error "schema response missing stats"))
  | _ -> raise (Back_error "bad schema response")

let fetch_stats st : Compile_stats.t =
  extract_stats (request_one st (Msgpack.Map [ (Msgpack.Str "type", Msgpack.Str "schema") ]))

let get_stats (st : state) : Compile_stats.t =
  Mutex.lock st.mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock st.mutex)
    (fun () ->
      let now = Unix.gettimeofday () in
      match st.stats with
      | Some s when now -. st.stats_at < ttl -> s
      | _ ->
        let s = fetch_stats st in
        st.stats <- Some s;
        st.stats_at <- now;
        s)

let invalidate_stats (st : state) : unit =
  Mutex.lock st.mutex;
  (try st.stats <- None with e -> Mutex.unlock st.mutex; raise e);
  Mutex.unlock st.mutex

(* ── datalog: compile locally, execute on the back ─────────────────── *)

(* client params arrive as wire values (msgpack) — re-encoded verbatim *)
let build_scheme_local (prog_wire : Bytes.t) (params : Msgpack.t list)
    (columns : string list) : Bytes.t =
  let b = Buffer.create 256 in
  Msgpack.encode_map_header b 6;
  Msgpack.encode b (Msgpack.Str "type");
  Msgpack.encode b (Msgpack.Str "scheme-local");
  Msgpack.encode b (Msgpack.Str "program");
  Buffer.add_bytes b prog_wire; (* raw wire bytes — value passthrough *)
  Msgpack.encode b (Msgpack.Str "params");
  Msgpack.encode_array_header b (List.length params);
  List.iter (Msgpack.encode b) params;
  Msgpack.encode b (Msgpack.Str "mode");
  Msgpack.encode b (Msgpack.Str "query");
  Msgpack.encode b (Msgpack.Str "columns");
  Msgpack.encode_array_header b (List.length columns);
  List.iter (fun c -> Msgpack.encode b (Msgpack.Str c)) columns;
  Buffer.to_bytes b

let compile_query st (query : string) : Bytes.t * string list =
  let attempt () =
    let stats = get_stats st in
    let prog, find_vars = Datalog_compile.compile_datalog_query query stats in
    (Sexpr.to_wire_bytes prog, find_vars)
  in
  (try attempt () with
   | Datalog_compile.Compile_error msg when String.length msg >= 27
                                          && String.sub msg 0 27 = "attribute resolution failed" ->
     (* stale schema: invalidate, refetch, retry once (same contract as
        the Nim front, connection.nim:203-219) *)
     invalidate_stats st;
     attempt ())

let compile_error_msg = function
  | Datalog_compile.Compile_error m -> m
  | e -> Printexc.to_string e

let rec handle_datalog st (client_fd : Unix.file_descr) (raw : Bytes.t)
    (m : Msgpack.t) : unit =
  let fields =
    match m with Msgpack.Map kvs -> kvs | _ -> []
  in
  let query =
    match Msgpack.member (Msgpack.Str "query") fields with
    | Some (Msgpack.Str q) -> q
    | _ ->
      write_frame client_fd (error_frame "datalog request missing query field");
      raise Exit
  in
  let params =
    match Msgpack.member (Msgpack.Str "params") fields with
    | Some (Msgpack.Array xs) -> xs
    | _ -> []
  in
  let explain =
    match Msgpack.member (Msgpack.Str "explain") fields with
    | Some (Msgpack.Bool b) -> b
    | _ -> false
  in
  (* tx-data EDN routes to the transactor via the back's datalog path *)
  let contains subs (s : string) =
    let sl = String.length subs and n = String.length s in
    let rec loop i = i + sl <= n && (String.sub s i sl = subs || loop (i + 1)) in
    loop 0
  in
  if contains ":db/add" query || contains ":db/retract" query then
    forward_raw st client_fd raw
  else if explain then
    (* EXPLAIN renders via the Nim compiler path on the back *)
    forward_raw st client_fd raw
  else begin
    let prog_wire, columns =
      try compile_query st query
      with e ->
        write_frame client_fd (error_frame (compile_error_msg e));
        raise Exit
    in
    with_back_conn st (fun back_fd ->
        write_frame back_fd (build_scheme_local prog_wire params columns);
        let rec relay () =
          let frame = read_frame back_fd in
          write_frame client_fd frame;
          let resp = Msgpack.decode frame in
          let more =
            match resp with
            | Msgpack.Map kvs ->
              (match Msgpack.member (Msgpack.Str "more") kvs with
               | Some (Msgpack.Bool b) -> b
               | _ -> false)
            | _ -> false
          in
          if more then relay ()
        in
        relay ())
  end

(* ── forwarding: raw frame verbatim, relay frames until more=false ─── *)

and forward_raw st (client_fd : Unix.file_descr) (raw : Bytes.t) : unit =
  with_back_conn st (fun back_fd ->
      write_frame back_fd raw;
      let rec relay () =
        let frame = read_frame back_fd in
        write_frame client_fd frame;
        let resp = Msgpack.decode frame in
        let more =
          match resp with
          | Msgpack.Map kvs ->
            (match Msgpack.member (Msgpack.Str "more") kvs with
             | Some (Msgpack.Bool b) -> b
             | _ -> false)
            | _ -> false
        in
        if more then relay ()
      in
      try relay () with
      | Back_error m -> write_frame client_fd (error_frame m))

(* ── connection loop ───────────────────────────────────────────────── *)

let get_type (m : Msgpack.t) : string =
  match m with
  | Msgpack.Map kvs ->
    (match Msgpack.member (Msgpack.Str "type") kvs with
     | Some (Msgpack.Str t) -> t
     | _ -> "")
  | _ -> ""

let serve_client st (fd : Unix.file_descr) : unit =
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with _ -> ())
    (fun () ->
      let exit_ = Exit in
      try
        while true do
          let raw = read_frame fd in
          match (try Some (Msgpack.decode raw) with _ -> None) with
          | None -> write_frame fd (error_frame "parse error: request must be an object")
          | Some m ->
            let t = get_type m in
            (try
               match t with
               | "datalog" -> handle_datalog st fd raw m
               | "tx" | "admin" | "kv" | "scheme" -> forward_raw st fd raw
               | "schema" ->
                 (* relayed AND refreshes the stats cache *)
                 (try
                    let resp = request_one st (Msgpack.decode raw) in
                    (try
                       st.stats <- Some (extract_stats resp);
                       st.stats_at <- Unix.gettimeofday ()
                     with _ -> ());
                    write_frame fd (frame_of_msgpack resp)
                  with e ->
                    (try write_frame fd (error_frame (Printexc.to_string e))
                     with _ -> raise exit_))
             | "" -> write_frame fd (error_frame "parse error: request must be an object with a type")
             | other -> write_frame fd (error_frame ("unknown request type: " ^ other))
             with Back_error m ->
               (try write_frame fd (error_frame m) with _ -> raise exit_)
             | e ->
               (try write_frame fd (error_frame (Printexc.to_string e))
                with _ -> ()))
        done
      with
      | Back_error _ -> ()   (* client closed mid-frame — expected *)
      | Exit -> ())

let () =
  let socket_path = ref "" in
  let back_path = ref "" in
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | [] -> ()
    | "--socket-path" :: v :: rest -> socket_path := v; parse rest
    | "--back-path" :: v :: rest -> back_path := v; parse rest
    | "--help" :: _ ->
      print_endline "Usage: front [--socket-path FRONT_SOCK] [--back-path INTERNAL_SOCK]";
      exit 0
    | _ :: rest -> parse rest
  in
  parse args;
  let xdg =
    match Sys.getenv_opt "XDG_RUNTIME_DIR" with
    | Some d when d <> "" -> d
    | _ -> Unix.getenv "HOME" ^ "/.local/state"
  in
  let runtime_dir = Filename.concat xdg "eavt" in
  let socket_path =
    if !socket_path = "" then
      Filename.concat runtime_dir "eavt-query-ocaml.sock"
    else !socket_path
  in
  let back_path =
    if !back_path = "" then
      Filename.concat runtime_dir "eavt-query-internal.sock"
    else !back_path
  in
  let st = make_state back_path in
  (try Unix.unlink socket_path with _ -> ());
  (try Unix.mkdir (Filename.dirname socket_path) 0o755 with _ -> ());
  let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind sock (Unix.ADDR_UNIX socket_path);
  Unix.listen sock 64;
  Printf.printf "eavt query front (ocaml) on %s -> back %s\n%!" socket_path back_path;
  while true do
    match Unix.accept sock with
    | fd, _ ->
      (match (try Some (Thread.create (serve_client st) fd) with _ -> None) with
       | Some _ -> ()
       | None -> (try Unix.close fd with _ -> ()))
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
  done

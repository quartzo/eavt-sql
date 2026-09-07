(* repl.ml — Datalog/tx REPL loop, mirroring eavt-repl-nim/src/repl.nim:
   dot commands, multi-line accumulation on bracket depth, EDN tx-data
   via the wire encoding, tab-separated output. *)

exception Disconnected of string

let exc_msg = function
  | Client.Server_error m -> m
  | Client.Server_disconnected m -> m
  | Edn.Edn_error m -> m
  | Msgpack.Error m -> m
  | e -> Printexc.to_string e

let safe (f : unit -> unit) =
  try f ()
  with
  | Client.Server_disconnected m -> raise (Disconnected m)
  | e -> prerr_endline ("Error: " ^ exc_msg e)

let starts_with prefix (s : string) =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let bracket_depth (s : string) =
  let (d, _, _) =
    String.fold_left
      (fun (d, in_str, esc) c ->
        if esc then (d, in_str, false)
        else if in_str then
          (match c with
           | '\\' -> (d, in_str, true)
           | '"' -> (d, false, false)
           | _ -> (d, in_str, false))
        else
          (match c with
           | '"' -> (d, true, false)
           | '[' -> (d + 1, in_str, false)
           | ']' -> (d - 1, in_str, false)
           | _ -> (d, in_str, false)))
      (0, false, false) s
  in
  d

let is_complete_statement stmt = starts_with "[" stmt && bracket_depth stmt = 0

let is_tx_data stmt =
  let contains needle (hay : string) =
    let nl = String.length needle and hl = String.length hay in
    let rec loop i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  contains ":db/add" stmt || contains ":db/retract" stmt

(* ── statement execution ───────────────────────────────────────────── *)

let print_chunk (c : Client.chunk) =
  List.iter (fun row -> print_endline (String.concat "\t" row)) c.rows

let execute_datalog t query =
  (try List.iter print_chunk (Client.datalog t query)
   with
   | Client.Server_disconnected _ as e -> raise e
   | e -> prerr_endline ("Error: " ^ exc_msg e))

let execute_tx t txdata_text =
  match
    (try Some (Edn.read_edn_vector txdata_text)
     with Edn.Edn_error msg ->
       prerr_endline ("Error: EDN parse: " ^ msg);
       None)
  with
  | None -> ()
  | Some ops -> (
    try print_endline (Client.tx t ops)
    with
    | Client.Server_disconnected _ as e -> raise e
    | e -> prerr_endline ("Error: " ^ exc_msg e))

(* ── dot commands ──────────────────────────────────────────────────── *)

let help_text = {|Dot commands (no semicolon):
  .quit, .exit           Exit the REPL
  .help                  Show this help
  .flush                 Request background flush (returns immediately)
  .flush-sync            Flush and wait for completion
  .gc                    Run blob GC now (report roots/blobs removed)
  .gc-dry                Dry-run GC (report only, removes nothing)
  .status                Database overview
  .tree                  Per-column-family stats
  .memtable              MemTable contents and sizes
  .dump [EAVT|AEVT|...|CF]  Dump active datoms (or KV CF if number >= 10)
  .kv-put <cf> <key> <value>  Put key-value pair (CFs >= 10)
  .kv-get <cf> <key>          Get value by key
  .kv-delete <cf> <key>       Delete key
  .kv-scan <cf>               Scan all pairs in a CF

Datalog queries end with ;   e.g.  [:find ?name :where [?e :person/name ?name]];
|}

let admin_cmd t command = safe (fun () -> print_endline (Client.admin t command))

let cmd_dump t index =
  safe (fun () -> List.iter print_chunk (Client.dump t index))

let cmd_kv_scan t cf =
  safe (fun () -> List.iter print_chunk (Client.kv_scan t cf))

let cmd_kv_put t cf key value = safe (fun () -> print_endline (Client.kv_put t cf key value))
let cmd_kv_get t cf key = safe (fun () -> print_endline (Client.kv_get t cf key))
let cmd_kv_delete t cf key = safe (fun () -> print_endline (Client.kv_delete t cf key))

let handle_dot t (line : string) : bool =
  let parts = String.split_on_char ' ' line |> List.filter (fun s -> s <> "") in
  match parts with
  | [] -> false
  | cmd0 :: args ->
    let arg i default = match List.nth_opt args i with Some a -> a | None -> default in
    let cf_of i =
      match List.nth_opt args i with
      | Some a -> (try Some (int_of_string a) with _ -> None)
      | None -> None
    in
    match String.lowercase_ascii cmd0 with
    | ".quit" | ".exit" -> true
    | ".help" -> print_string help_text; print_newline (); false
    | ".flush" -> admin_cmd t "flush"; false
    | ".flush-sync" -> admin_cmd t "flush-sync"; false
    | ".gc" -> admin_cmd t "gc"; false
    | ".gc-dry" -> admin_cmd t "gc-dry"; false
    | ".status" -> admin_cmd t "status"; false
    | ".tree" -> admin_cmd t "tree"; false
    | ".memtable" -> admin_cmd t "memtable"; false
    | ".dump" ->
      let a = arg 0 "EAVT" in
      let cf_num = try int_of_string a with _ -> -1 in
      if cf_num >= 10 then (cmd_kv_scan t cf_num; false)
      else
        let index = String.uppercase_ascii a in
        if List.mem index [ "EAVT"; "AEVT"; "AVET"; "VAET" ] then (cmd_dump t index; false)
        else begin
          prerr_endline
            "Error: index must be one of EAVT, AEVT, AVET, VAET or a CF number >= 10";
          false
        end
    | ".kv-put" ->
      if List.length args < 3 then (prerr_endline "Usage: .kv-put <cf> <key> <value>"; false)
      else
        (match cf_of 0 with
         | Some cf when cf >= 10 -> cmd_kv_put t cf (List.nth args 1) (List.nth args 2); false
         | _ -> prerr_endline "Error: cf must be >= 10 for key-value operations"; false)
    | ".kv-get" ->
      if List.length args < 2 then (prerr_endline "Usage: .kv-get <cf> <key>"; false)
      else
        (match cf_of 0 with
         | Some cf when cf >= 10 -> cmd_kv_get t cf (List.nth args 1); false
         | _ -> prerr_endline "Error: cf must be >= 10 for key-value operations"; false)
    | ".kv-delete" ->
      if List.length args < 2 then (prerr_endline "Usage: .kv-delete <cf> <key>"; false)
      else
        (match cf_of 0 with
         | Some cf when cf >= 10 -> cmd_kv_delete t cf (List.nth args 1); false
         | _ -> prerr_endline "Error: cf must be >= 10 for key-value operations"; false)
    | ".kv-scan" ->
      if List.length args < 1 then (prerr_endline "Usage: .kv-scan <cf>"; false)
      else
        (match cf_of 0 with
         | Some cf when cf >= 10 -> cmd_kv_scan t cf; false
         | _ -> prerr_endline "Error: cf must be >= 10 for key-value operations"; false)
    | _ -> prerr_endline ("Unknown command: " ^ line); false

(* ── REPL loop ─────────────────────────────────────────────────────── *)

type mode = Interactive | Pipe | Exec of string

let history_file () = Filename.concat (Unix.getenv "HOME") ".eavt_datalog_history"

let banner sock_path =
  print_endline ("eavt datalog repl: socket=" ^ sock_path);
  print_endline "Queries: [:find ?v :where [?e :attr ?v]];";
  print_endline "Type .help for commands, .quit to exit";
  print_endline ""

let read_stdin prompt =
  print_string prompt;
  flush stdout;
  (try Some (input_line stdin) with End_of_file -> None)

let read_line mode prompt =
  match mode with
  | Interactive -> LNoise.linenoise prompt
  | Pipe -> read_stdin prompt
  | Exec cmd -> if cmd = "" then None else Some cmd

let process_statement t interactive trimmed =
  if interactive then ignore (LNoise.history_add trimmed);
  if is_tx_data trimmed then execute_tx t trimmed else execute_datalog t trimmed

let rec loop t mode interactive accumulated =
  let prompt = if accumulated = "" then "eavt-dl> " else "       -> " in
  match read_line mode prompt with
  | None ->
    print_endline "";
    (match mode with
     | Exec _ -> ()
     | _ -> flush stdout)
  | Some line ->
    let stripped = String.trim line in
    if accumulated = "" && stripped <> "" && stripped.[0] = '.' then begin
      if interactive then ignore (LNoise.history_add line);
      (try
         if not (handle_dot t stripped) then loop t mode interactive accumulated
       with Disconnected m -> prerr_endline ("\nError: " ^ m))
    end
    else if starts_with "--" stripped then loop t mode interactive accumulated
    else begin
      let cmd = (match mode with Exec _ -> "" | _ -> accumulated) ^ line ^ " " in
      let trimmed = String.trim cmd in
      if trimmed <> "" && is_complete_statement trimmed then begin
        process_statement t interactive trimmed;
        (match mode with
         | Exec _ -> ()
         | _ -> loop t mode interactive "")
      end
      else
        (match mode with
         | Exec _ -> loop t (Exec "") interactive trimmed
         | _ -> loop t mode interactive cmd)
    end

let run ?(sock_path) mode =
  let sock_path = match sock_path with Some p -> p | None -> Client.socket_path () in
  let t =
    match Client.try_connect sock_path with
    | Some t -> t
    | None ->
      prerr_endline ("Error: cannot connect to " ^ sock_path);
      exit 1
  in
  let mode =
    match mode with
    | Interactive when not (Unix.isatty Unix.stdin) -> Pipe
    | m -> m
  in
  let interactive = mode = Interactive in
  (match mode with Exec _ -> () | _ -> banner sock_path);
  if mode = Interactive then ignore (LNoise.history_load ~filename:(history_file ()));
  (match mode with
   | Exec cmd ->
     let trimmed = String.trim cmd in
     if trimmed <> "" && trimmed.[0] = '.' then
       (try ignore (handle_dot t trimmed) with Disconnected m -> prerr_endline ("Error: " ^ m))
     else if trimmed <> "" && is_complete_statement trimmed then
       (try process_statement t false trimmed
        with Disconnected m -> prerr_endline ("Error: " ^ m))
     else if trimmed <> "" then prerr_endline "Error: incomplete statement"
   | _ -> loop t mode interactive "");
  if mode = Interactive then ignore (LNoise.history_save ~filename:(history_file ()));
  Client.close t

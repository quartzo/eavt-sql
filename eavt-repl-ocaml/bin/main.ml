(* main.ml — entry point: optional <SOCKET_PATH>, --help, -e "cmd",
   pipe mode (stdin not a TTY), interactive REPL. *)

let usage =
  {|Usage: eavt-sql-cli-ocaml [OPTIONS] [SOCKET_PATH]

Options:
  --help, -h              Show this help
  -e, --execute "query"   Execute a Datalog query and exit
  SOCKET_PATH             Unix socket path (default: auto-detect)

Modes:
  Interactive:    eavt-sql-cli-ocaml                   (REPL with history)
  Execute:        eavt-sql-cli-ocaml -e "[:find ?v :where [_ :dummy/x ?v]]"   (run and exit)
  Pipe:           echo "[:find ?v :where [?e :attr ?v]]" | eavt-sql-cli-ocaml (read stdin, no prompt)
|}

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let sock_path = ref "" in
  let exec_cmd = ref "" in
  let rec parse = function
    | [] -> ()
    | arg :: rest ->
      (match arg with
       | "--help" | "-h" ->
         print_string usage;
         exit 0
       | "-e" | "--execute" ->
         (match rest with
          | cmd :: rest' ->
            exec_cmd := cmd;
            parse rest'
          | [] ->
            prerr_endline ("Error: " ^ arg ^ " requires an argument");
            exit 1)
       | a when String.length a > 0 && a.[0] = '-' ->
         prerr_endline ("Unknown option: " ^ a);
         prerr_string usage;
         exit 1
       | a ->
         sock_path := a;
         parse rest)
  in
  parse args;
  let sock_path =
    if !sock_path = "" then Eavt_repl.Client.socket_path () else !sock_path
  in
  let mode = if !exec_cmd = "" then Eavt_repl.Repl.Interactive else Eavt_repl.Repl.Exec !exec_cmd in
  try Eavt_repl.Repl.run ~sock_path mode with
  | e ->
    prerr_endline ("Error: " ^ Printexc.to_string e);
    exit 1

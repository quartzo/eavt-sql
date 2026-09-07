(* zipsrc.ml — zip byte streams via the `unzip` subprocess: the child
   decompresses on its own core and streams through the pipe while the
   loader parses/encodes on the main core.  One-deep prefetch: spawn the
   next zip's process before finishing the current one so decompression
   of file N+1 overlaps parsing of file N.  Fail-loud on nonzero exit. *)

type stream = {
  path : string;
  ic : in_channel;
  mutable finished : bool;
}

let spawn (path : string) : stream =
  let cmd = Printf.sprintf "unzip -p %s" (Filename.quote path) in
  let ic = Unix.open_process_in cmd in
  { path; ic; finished = false }

(* one-deep prefetch queue *)
let queue : stream Queue.t = Queue.create ()

let prefetch (path : string) = Queue.push (spawn path) queue

let open_zip (path : string) : stream =
  if Queue.is_empty queue then spawn path
  else (
    let s = Queue.pop queue in
    if s.path <> path then invalid_arg "zipsrc: prefetched path mismatch";
    s)

let read (s : stream) (buf : Bytes.t) off len : int =
  input s.ic buf off len

let finish (s : stream) : unit =
  if not s.finished then begin
    s.finished <- true;
    let status = Unix.close_process_in s.ic in
    match status with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED n ->
      raise (Failure (Printf.sprintf "unzip %s: exit %d" s.path n))
    | Unix.WSIGNALED n ->
      (* SIGPIPE: o loader parou de ler antes do fim (--n) — esperado.
         Outros sinais: avisa e segue (o que foi lido já foi aplicado). *)
      if n <> 13 && n <> -8 then
        prerr_endline (Printf.sprintf "warn: unzip %s terminou com sinal %d" s.path n)
    | Unix.WSTOPPED n ->
      raise (Failure (Printf.sprintf "unzip %s: stopped %d" s.path n))
  end

let find_zip (data_dir : string) (prefix : string) : string =
  (* like the Python find_zip: first {prefix}*.zip in the directory *)
  let dir = Sys.readdir data_dir in
  let matches =
    Array.to_list dir
    |> List.filter (fun f ->
           String.length f > String.length prefix
           && String.sub f 0 (String.length prefix) = prefix
           && Filename.check_suffix f ".zip")
    |> List.sort compare
  in
  match matches with
  | f :: _ -> Filename.concat data_dir f
  | [] -> raise (Failure (Printf.sprintf "no %s*.zip in %s" prefix data_dir))

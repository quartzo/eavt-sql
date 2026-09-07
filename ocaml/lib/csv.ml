(* csv.ml — streaming CSV reader over a Unix fd (the unzip pipe):
   quoted fields, ';' delimiter, "" escape, newlines inside quotes,
   latin-1 bytes pass through untouched.  Mirrors Python's csv.reader
   semantics for the Receita layout (all fields quoted, one record per
   line): a blank line yields []. *)

type t = {
  fd : Unix.file_descr;
  buf : Bytes.t;
  mutable pos : int;
  mutable len : int;
  mutable eof : bool;
  mutable cr_pending : bool; (* saw '\r' row-end; swallow a following '\n' *)
}

let create fd =
  { fd; buf = Bytes.create 65536; pos = 0; len = 0; eof = false; cr_pending = false }

let raw_char t =
  if t.pos >= t.len then begin
    if t.eof then None
    else begin
      let n = Unix.read t.fd t.buf 0 (Bytes.length t.buf) in
      if n <= 0 then (t.eof <- true; None)
      else begin
        t.len <- n;
        t.pos <- 0;
        let c = Char.code (Bytes.get t.buf 0) in
        t.pos <- 1;
        Some c
      end
    end
  end else begin
    let c = Char.code (Bytes.get t.buf t.pos) in
    t.pos <- t.pos + 1;
    Some c
  end

let getchar t =
  if t.cr_pending then begin
    t.cr_pending <- false;
    match raw_char t with
    | Some 10 -> raw_char t (* swallow the \n of a \r\n *)
    | x -> x
  end
  else raw_char t

let next_row (t : t) : string list option =
  match getchar t with
  | None -> None
  | Some c0 ->
    let delim = Char.code ';' in
    let fields = ref [] in
    let cur = Buffer.create 64 in
    let finish_field () =
      fields := Buffer.contents cur :: !fields;
      Buffer.clear cur
    in
    (* pending first char of the row *)
    let st =
      ref
        (if c0 = Char.code '"' then `Qtd
         else if c0 = 10 then `Done
         else if c0 = 13 then (t.cr_pending <- true; `Done)
         else if c0 = delim then (finish_field (); `FStart)
         else (Buffer.add_char cur (Char.chr c0); `Unq))
    in
    let rec loop () =
      match getchar t with
      | None ->
        (* EOF: flush the trailing field *)
        if !st <> `Done then finish_field ()
      | Some c ->
        (match !st with
         | `FStart ->
           if c = Char.code '"' then st := `Qtd
           else if c = delim then finish_field ()
           else if c = 10 then (finish_field (); st := `Done)
           else if c = 13 then (t.cr_pending <- true; finish_field (); st := `Done)
           else (Buffer.add_char cur (Char.chr c); st := `Unq)
         | `Unq ->
           if c = delim then (finish_field (); st := `FStart)
           else if c = 10 then (finish_field (); st := `Done)
           else if c = 13 then (t.cr_pending <- true; finish_field (); st := `Done)
           else Buffer.add_char cur (Char.chr c)
         | `Qtd ->
           if c = Char.code '"' then st := `QEsc
           else Buffer.add_char cur (Char.chr c)
         | `QEsc ->
           if c = Char.code '"' then (Buffer.add_char cur '"'; st := `Qtd)
           else if c = delim then (finish_field (); st := `FStart)
           else if c = 10 then (finish_field (); st := `Done)
           else if c = 13 then (t.cr_pending <- true; finish_field (); st := `Done)
           else (Buffer.add_char cur (Char.chr c); st := `Qtd)
         | `Done -> ());
        if !st <> `Done then loop ()
    in
    if !st <> `Done then loop ();
    if c0 = 10 then Some [] (* blank line, like Python csv: empty row *)
    else Some (List.rev !fields)

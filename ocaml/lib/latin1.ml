(* latin1.ml — latin-1 → UTF-8 at the wire boundary: the Python loader
   reads source files as latin-1 and msgpack-encodes the resulting
   unicode as UTF-8; byte streams here must do the same conversion or
   the server stores different bytes. *)

let to_utf8 (s : string) : string =
  let n = String.length s in
  let needs = ref false in
  String.iter (fun c -> if Char.code c >= 0x80 then needs := true) s;
  if not !needs then s
  else
    let buf = Buffer.create (n * 2) in
    String.iter
      (fun c ->
        let b = Char.code c in
        if b < 0x80 then Buffer.add_char buf c
        else (
          Buffer.add_char buf (Char.chr (0xC0 lor (b lsr 6)));
          Buffer.add_char buf (Char.chr (0x80 lor (b land 0x3F)))))
      s;
    Buffer.contents buf

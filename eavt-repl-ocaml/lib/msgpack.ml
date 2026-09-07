(* msgpack.ml — minimal MessagePack encoder/decoder, hand-rolled so that
   the application ext types (0x05 symbol, 0x06 keyword) round-trip.
   Decode is fail-loud: truncated input, unknown format bytes and
   out-of-range lengths raise [Error].  Map keys are [t] so integer
   keys (tx-report tempids) decode like any other key. *)

exception Error of string

type t =
  | Nil
  | Bool of bool
  | Int of int64
  | Float of float
  | Str of string
  | Bin of Bytes.t
  | Array of t list
  | Map of (t * t) list
  | Ext of int * Bytes.t

let ext_symbol = 5
let ext_keyword = 6

(* ── encode ────────────────────────────────────────────────────────── *)

let add_u8 buf b = Buffer.add_char buf (Char.chr (b land 0xff))

let add_be16 buf n =
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (n land 0xff))

let add_be32 buf n =
  Buffer.add_char buf (Char.chr ((n lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (n land 0xff))

let add_be64 buf (n : int64) =
  for shift = 7 downto 0 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical n (shift * 8)) 0xffL)))
  done

let encode_int buf (v : int64) =
  if v >= 0L && v <= 0x7fL then add_u8 buf (Int64.to_int v)
  else if v < 0L && v >= -32L then add_u8 buf (Int64.to_int v land 0xff)
  else if v >= 0L && v <= 0xffL then (add_u8 buf 0xcc; add_u8 buf (Int64.to_int v))
  else if v < 0L && v >= -128L then (add_u8 buf 0xd0; add_u8 buf (Int64.to_int v))
  else if v >= 0L && v <= 0xffffL then (add_u8 buf 0xcd; add_be16 buf (Int64.to_int v))
  else if v < 0L && v >= -32768L then
    (add_u8 buf 0xd1; add_be16 buf (Int64.to_int (Int64.logand v 0xffffL)))
  else if v >= 0L && v <= 0xffffffffL then (add_u8 buf 0xce; add_be32 buf (Int64.to_int v))
  else if v < 0L && v >= -2147483648L then
    (add_u8 buf 0xd2; add_be32 buf (Int64.to_int (Int64.logand v 0xffffffffL)))
  else (add_u8 buf 0xd3; add_be64 buf v)

let encode_str buf s =
  let len = String.length s in
  if len <= 31 then add_u8 buf (0xa0 lor len)
  else if len <= 0xff then (add_u8 buf 0xd9; add_u8 buf len)
  else if len <= 0xffff then (add_u8 buf 0xda; add_be16 buf len)
  else (add_u8 buf 0xdb; add_be32 buf len);
  Buffer.add_string buf s

let encode_bin buf s =
  let len = Bytes.length s in
  if len <= 0xff then (add_u8 buf 0xc4; add_u8 buf len)
  else if len <= 0xffff then (add_u8 buf 0xc5; add_be16 buf len)
  else (add_u8 buf 0xc6; add_be32 buf len);
  Buffer.add_bytes buf s

let encode_array_header buf n =
  if n <= 15 then add_u8 buf (0x90 lor n)
  else if n <= 0xffff then (add_u8 buf 0xdc; add_be16 buf n)
  else (add_u8 buf 0xdd; add_be32 buf n)

let encode_map_header buf n =
  if n <= 15 then add_u8 buf (0x80 lor n)
  else if n <= 0xffff then (add_u8 buf 0xde; add_be16 buf n)
  else (add_u8 buf 0xdf; add_be32 buf n)

let encode_ext buf ty payload =
  let len = Bytes.length payload in
  if len <= 0xff then (add_u8 buf 0xc7; add_u8 buf len)
  else if len <= 0xffff then (add_u8 buf 0xc8; add_be16 buf len)
  else (add_u8 buf 0xc9; add_be32 buf len);
  add_u8 buf (ty land 0xff);
  Buffer.add_bytes buf payload

let rec encode buf = function
  | Nil -> add_u8 buf 0xc0
  | Bool false -> add_u8 buf 0xc2
  | Bool true -> add_u8 buf 0xc3
  | Int v -> encode_int buf v
  | Float f -> add_u8 buf 0xcb; add_be64 buf (Int64.bits_of_float f)
  | Str s -> encode_str buf s
  | Bin s -> encode_bin buf s
  | Array xs -> encode_array_header buf (List.length xs); List.iter (encode buf) xs
  | Map kvs ->
    encode_map_header buf (List.length kvs);
    List.iter (fun (k, v) -> encode buf k; encode buf v) kvs
  | Ext (ty, payload) -> encode_ext buf ty payload

(* ── decode ────────────────────────────────────────────────────────── *)

let u8 buf pos =
  if pos >= Bytes.length buf then raise (Error "truncated");
  Char.code (Bytes.get buf pos)

let u16 buf pos =
  if pos + 2 > Bytes.length buf then raise (Error "truncated");
  (Char.code (Bytes.get buf pos) lsl 8) lor Char.code (Bytes.get buf (pos + 1))

let u32 buf pos =
  if pos + 4 > Bytes.length buf then raise (Error "truncated");
  (Char.code (Bytes.get buf pos) lsl 24)
  lor (Char.code (Bytes.get buf (pos + 1)) lsl 16)
  lor (Char.code (Bytes.get buf (pos + 2)) lsl 8)
  lor Char.code (Bytes.get buf (pos + 3))

let u64 buf pos =
  let hi = Int64.of_int (u32 buf pos) in
  let lo = Int64.of_int (u32 buf (pos + 4)) in
  Int64.logor (Int64.shift_left hi 32) lo

let take buf pos len =
  if pos + len > Bytes.length buf then raise (Error "truncated");
  Bytes.sub buf pos len

let show_value = function
  | Nil -> "nil"
  | Bool _ -> "bool"
  | Int _ -> "int"
  | Float _ -> "float"
  | Str _ -> "str"
  | Bin _ -> "bin"
  | Array _ -> "array"
  | Map _ -> "map"
  | Ext _ -> "ext"

let compare_key (a : t) (b : t) = compare a b

let rec decode_value buf pos : t * int =
  let b = u8 buf pos in
  let pos = pos + 1 in
  if b <= 0x7f then (Int (Int64.of_int b), pos)
  else if b >= 0xe0 then (Int (Int64.of_int (b - 0x100)), pos)
  else if b >= 0x90 && b <= 0x9f then
    (* fixarray *)
    let n = b land 0x0f in
    let rec loop pos i acc =
      if i = n then (List.rev acc, pos)
      else
        let (v, pos) = decode_value buf pos in
        loop pos (i + 1) (v :: acc)
    in
    let (xs, pos) = loop pos 0 [] in
    (Array xs, pos)
  else if b >= 0xa0 && b <= 0xbf then
    let n = b land 0x1f in
    (Str (Bytes.to_string (take buf pos n)), pos + n)
  else if b >= 0x80 && b <= 0x8f then
    (* fixmap *)
    let n = b land 0x0f in
    let rec loop pos i acc =
      if i = n then (List.rev acc, pos)
      else
        let (k, pos) = decode_value buf pos in
        let (v, pos) = decode_value buf pos in
        loop pos (i + 1) ((k, v) :: acc)
    in
    let (kvs, pos) = loop pos 0 [] in
    (Map kvs, pos)
  else
    match b with
    | 0xc0 -> (Nil, pos)
    | 0xc2 -> (Bool false, pos)
    | 0xc3 -> (Bool true, pos)
    | 0xc4 | 0xc5 | 0xc6 ->
      let n = (match b with 0xc4 -> u8 buf pos | 0xc5 -> u16 buf pos | _ -> u32 buf pos) in
      let hdr = (match b with 0xc4 -> 1 | 0xc5 -> 2 | _ -> 4) in
      (Bin (take buf (pos + hdr) n), pos + hdr + n)
    | 0xc7 | 0xc8 | 0xc9 ->
      let n = (match b with 0xc7 -> u8 buf pos | 0xc8 -> u16 buf pos | _ -> u32 buf pos) in
      let hdr = (match b with 0xc7 -> 1 | 0xc8 -> 2 | _ -> 4) in
      if n > Bytes.length buf then raise (Error "ext length out of range");
      let ty = u8 buf (pos + hdr) in
      (Ext (ty, take buf (pos + hdr + 1) n), pos + hdr + 1 + n)
    | 0xca ->
      let bits = Int32.of_int (u32 buf pos) in
      (Float (Int32.float_of_bits bits), pos + 4)
    | 0xcb -> (Float (Int64.float_of_bits (u64 buf pos)), pos + 8)
    | 0xcc -> (Int (Int64.of_int (u8 buf pos)), pos + 1)
    | 0xcd -> (Int (Int64.of_int (u16 buf pos)), pos + 2)
    | 0xce -> (Int (Int64.of_int (u32 buf pos)), pos + 4)
    | 0xcf -> (Int (u64 buf pos), pos + 8)
    | 0xd0 ->
      let v = Int64.of_int (u8 buf pos) in
      (Int (Int64.sub v (Int64.of_int 0x100)), pos + 1)
    | 0xd1 ->
      let v = Int64.of_int (u16 buf pos) in
      let v = if v > 32767L then Int64.sub v 65536L else v in
      (Int v, pos + 2)
    | 0xd2 ->
      let v = Int64.of_int (u32 buf pos) in
      let v = if v > 2147483647L then Int64.sub v 4294967296L else v in
      (Int v, pos + 4)
    | 0xd3 -> (Int (u64 buf pos), pos + 8)
    | 0xd4 | 0xd5 | 0xd6 | 0xd7 | 0xd8 ->
      (* fixext 1/2/4/8/16 *)
      let n = 1 lsl (b - 0xd4) in
      let ty = u8 buf pos in
      (Ext (ty, take buf (pos + 1) n), pos + 1 + n)
    | 0xd9 | 0xda | 0xdb ->
      let n = (match b with 0xd9 -> u8 buf pos | 0xda -> u16 buf pos | _ -> u32 buf pos) in
      let hdr = (match b with 0xd9 -> 1 | 0xda -> 2 | _ -> 4) in
      (Str (Bytes.to_string (take buf (pos + hdr) n)), pos + hdr + n)
    | 0xdc | 0xdd ->
      let n = (match b with 0xdc -> u16 buf pos | _ -> u32 buf pos) in
      let hdr = (match b with 0xdc -> 2 | _ -> 4) in
      let rec loop pos i acc =
        if i = n then (List.rev acc, pos)
        else
          let (v, pos) = decode_value buf pos in
          loop pos (i + 1) (v :: acc)
      in
      let (xs, pos) = loop (pos + hdr) 0 [] in
      (Array xs, pos)
    | 0xde | 0xdf ->
      let n = (match b with 0xde -> u16 buf pos | _ -> u32 buf pos) in
      let hdr = (match b with 0xde -> 2 | _ -> 4) in
      let rec loop pos i acc =
        if i = n then (List.rev acc, pos)
        else
          let (k, pos) = decode_value buf pos in
          let (v, pos) = decode_value buf pos in
          loop pos (i + 1) ((k, v) :: acc)
      in
      let (kvs, pos) = loop (pos + hdr) 0 [] in
      (Map kvs, pos)
    | _ -> raise (Error (Printf.sprintf "unknown format byte 0x%02x at pos %d" b (pos - 1)))

let decode buf =
  let (v, pos) = decode_value buf 0 in
  if pos <> Bytes.length buf then
    raise (Error (Printf.sprintf "trailing content at pos %d" pos));
  v

let decode_at buf pos = decode_value buf pos

let get_str = function
  | Str s -> s
  | Bin b -> Bytes.to_string b
  | v -> raise (Error (Printf.sprintf "expected str, got %s" (show_value v)))

let get_int = function
  | Int i -> i
  | v -> raise (Error (Printf.sprintf "expected int, got %s" (show_value v)))

let member key kvs =
  let rec loop = function
    | [] -> None
    | (k, v) :: rest -> if compare_key k key = 0 then Some v else loop rest
  in
  loop kvs

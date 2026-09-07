(* sexpr.ml — Scheme S-expression AST + wire encoder, mirroring
   nim_scheme/scheme.nim's SExpr and wire.nim's writeSExprWire:
   int/float/str/bool/void/list map onto native msgpack; symbol →
   ext 0x05, keyword → ext 0x06.  The compile gate is byte-identity
   with the Nim compiler's wire output. *)

type t =
  | S_int of int64
  | S_float of float
  | S_str of string
  | S_bool of bool
  | S_void
  | S_symbol of string
  | S_keyword of string
  | S_list of t list

let rec encode_wire (buf : Buffer.t) (e : t) : unit =
  match e with
  | S_int v -> Msgpack.encode buf (Msgpack.Int v)
  | S_float f -> Msgpack.encode buf (Msgpack.Float f)
  | S_str s -> Msgpack.encode buf (Msgpack.Str s)
  | S_bool b -> Msgpack.encode buf (Msgpack.Bool b)
  | S_void -> Msgpack.encode buf Msgpack.Nil
  | S_symbol s ->
    Msgpack.encode buf (Msgpack.Ext (Msgpack.ext_symbol, Bytes.of_string s))
  | S_keyword s ->
    Msgpack.encode buf (Msgpack.Ext (Msgpack.ext_keyword, Bytes.of_string s))
  | S_list items ->
    Msgpack.encode_array_header buf (List.length items);
    List.iter (encode_wire buf) items

let to_wire_bytes (e : t) : Bytes.t =
  let buf = Buffer.create 256 in
  encode_wire buf e;
  Buffer.to_bytes buf

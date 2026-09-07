module M = Eavt_repl.Msgpack
module Edn = Eavt_repl.Edn

let check name cond =
  if not cond then (
    Printf.eprintf "FAIL: %s\n%!" name;
    exit 1)
  else Printf.printf "[OK] %s\n%!" name

let rt (v : M.t) : M.t =
  let buf = Buffer.create 16 in
  M.encode buf v;
  M.decode (Buffer.to_bytes buf)

let () =
  (* msgpack roundtrips *)
  check "int 0" (rt (M.Int 0L) = M.Int 0L);
  check "int 127" (rt (M.Int 127L) = M.Int 127L);
  check "int -32" (rt (M.Int (-32L)) = M.Int (-32L));
  check "int 128" (rt (M.Int 128L) = M.Int 128L);
  check "int -33" (rt (M.Int (-33L)) = M.Int (-33L));
  check "int 255" (rt (M.Int 255L) = M.Int 255L);
  check "int 65536" (rt (M.Int 65536L) = M.Int 65536L);
  check "int max_int64" (rt (M.Int Int64.max_int) = M.Int Int64.max_int);
  check "int min_int64" (rt (M.Int Int64.min_int) = M.Int Int64.min_int);
  check "float" (rt (M.Float 1.5) = M.Float 1.5);
  check "str" (rt (M.Str "hello") = M.Str "hello");
  check "str empty" (rt (M.Str "") = M.Str "");
  check "str long" (rt (M.Str (String.make 300 'x')) = M.Str (String.make 300 'x'));
  check "bool" (rt (M.Bool true) = M.Bool true);
  check "nil" (rt M.Nil = M.Nil);
  check "bin" (
    rt (M.Bin (Bytes.of_string "\x00\xff\x01")) = M.Bin (Bytes.of_string "\x00\xff\x01"));
  check "array" (
    rt (M.Array [ M.Int 1L; M.Str "a" ])
    = M.Array [ M.Int 1L; M.Str "a" ]);
  check "nested array" (
    rt (M.Array [ M.Array [ M.Nil ] ])
    = M.Array [ M.Array [ M.Nil ] ]);
  check "map with int keys" (
    rt (M.Map [ (M.Int 1L, M.Str "x"); (M.Str "k", M.Int 2L) ])
    = M.Map [ (M.Int 1L, M.Str "x"); (M.Str "k", M.Int 2L) ]);
  check "ext symbol" (
    rt (M.Ext (M.ext_symbol, Bytes.of_string "?e")) = M.Ext (5, Bytes.of_string "?e"));
  check "ext keyword" (
    rt (M.Ext (M.ext_keyword, Bytes.of_string "person/name"))
    = M.Ext (6, Bytes.of_string "person/name"));

  (* decoder fail-loud *)
  let truncated () =
    let buf = Buffer.create 16 in
    M.encode buf (M.Str "abcdef");
    let b = Buffer.to_bytes buf in
    M.decode (Bytes.sub b 0 5)
  in
  check "truncated raises"
    (try (ignore (truncated ()); false) with M.Error _ -> true);
  let bad_byte () =
    M.decode (Bytes.of_string "\xc1")
  in
  check "unknown format byte raises"
    (try (ignore (bad_byte ()); false) with M.Error _ -> true);

  (* edn *)
  let open Edn in
  (match read_edn_vector "[[:db/add -1 :person/name \"Alice\"]]" with
   | [ List [ Keyword "db/add"; Int (-1L); Keyword "person/name"; Str "Alice" ] ] ->
     check "edn tx vector" true
   | _ -> check "edn tx vector" false);
  (match read_edn_vector "[ 1 , 2.5 , true , false , nil , _ , ?v ]" with
   | [ Int 1L; Float 2.5; Bool true; Bool false; Nil; Symbol "_"; Symbol "?v" ] ->
     check "edn atoms + commas" true
   | _ -> check "edn atoms + commas" false);
  (match read_edn_vector "[\"a\\nb\"]" with
   | [ Str "a\nb" ] -> check "edn escapes" true
   | _ -> check "edn escapes" false);
  check "edn trailing content raises"
    (try (ignore (read_edn "[1] extra"); false) with Edn_error _ -> true);
  check "edn vector trailing ignored like nim"
    (read_edn_vector "[1] extra" = [ Int 1L ]);
  check "edn maps rejected"
    (try (ignore (read_edn "{:a 1}"); false) with Edn_error _ -> true);
  check "edn empty vector parses" (read_edn_vector "[ ]" = [])

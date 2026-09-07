module M = Eavt_lib.Msgpack
module Edn = Eavt_lib.Edn
module Sha = Eavt_lib.Sha256

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
;;

(* ── sha256 ─────────────────────────────────────────────────────────── *)
let hex_of s = Sha.hex (Sha.digest s)
;;

check "sha256 empty" (hex_of "" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
check "sha256 abc" (hex_of "abc" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
check "sha256 55 bytes" (hex_of (String.make 55 'a') = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
check "sha256 56 bytes" (hex_of (String.make 56 'a') = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
check "sha256 64 bytes" (hex_of (String.make 64 'a') = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
check "sha256 b64url tag exact" (
  String.sub (Sha.b64url (Sha.digest "abc")) 0 6 = "ungWv4");

(* ── latin1 ─────────────────────────────────────────────────────────── *)
check "latin1 ascii passthrough" (Eavt_lib.Latin1.to_utf8 "abc" = "abc");
check "latin1 acentos" (
  Eavt_lib.Latin1.to_utf8 "A\231\227o" = "A\195\167\195\163o");
;;

(* ── csv ────────────────────────────────────────────────────────────── *)
(* write all (small data fits the 64 KiB pipe buffer), close the write
   end, then read *)
let csv_rows (data : string) : string list list =
  let (rfd, wfd) = Unix.pipe () in
  let w = Unix.out_channel_of_descr wfd in
  output_string w data;
  close_out w;
  let t = Eavt_lib.Csv.create rfd in
  let rows = ref [] in
  let rec loop () =
    match Eavt_lib.Csv.next_row t with
    | None -> ()
    | Some row -> rows := row :: !rows; loop ()
  in
  loop ();
  Unix.close rfd;
  List.rev !rows

let () =
  let rows = csv_rows "\"a\";\"b;c\";\"d\"\"e\"\n\"f\";;\"h\"\n\n\"i\"\r\n\"multi\nline\";x\n" in
  check "csv quoted+escape" (
    rows = [ [ "a"; "b;c"; "d\"e" ]; [ "f"; ""; "h" ]; []; [ "i" ]; [ "multi\nline"; "x" ] ]);
  let rows = csv_rows "\"unterminated" in
  check "csv eof flushes field" (rows = [ [ "unterminated" ] ]);
  let rows = csv_rows "" in
  check "csv empty input" (rows = [])

(* ── golden: compilador Nim vs OCaml (Fase 2) *)

let read_file (path : string) : string =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let golden_count = 25

let () =
  let total = ref 0 in
  let failed = ref 0 in
  for i = 1 to golden_count do
    let n = Printf.sprintf "%02d" i in
    let query = read_file (Sys.file_exists "golden" |> ignore; "golden/q" ^ n ^ ".q") in
    let expected = read_file ("golden/w" ^ n ^ ".wire") in
    let stats_bytes = read_file ("golden/s" ^ n ^ ".stats") in
    incr total;
    let result =
      try
        let stats =
          Eavt_lib.Compile_stats.decode (Eavt_lib.Msgpack.decode (Bytes.of_string stats_bytes))
        in
        let prog, _find_vars, ordered_vars, iter_plans =
          Eavt_lib.Datalog_compile.compile_datalog_query_debug query stats
        in
        let wire = Eavt_lib.Sexpr.to_wire_bytes prog in
        if String.of_bytes wire = expected then `Ok
        else begin
          let oc = open_out_bin ("golden/q" ^ n ^ ".got") in
          output_string oc (String.of_bytes wire);
          close_out oc;
          `Diff (Bytes.length wire, String.length expected,
                 String.concat "," ordered_vars ^ " | "
                 ^ String.concat ","
                   (List.map (fun ip -> ip.Eavt_lib.Planner.index_name) iter_plans))
        end
      with
      | e -> `Error (Printexc.to_string e)
    in
    (match result with
     | `Ok -> Printf.printf "[GOLDEN OK] q%s\n%!" n
     | `Diff (got_len, exp_len, fv) ->
       incr failed;
       Printf.printf "[GOLDEN FAIL] q%s: %dB vs %dB (find=%s)\n%!" n got_len exp_len fv
     | `Error msg ->
       incr failed;
       Printf.printf "[GOLDEN ERROR] q%s: %s\n%!" n msg)
  done;
  Printf.printf "golden: %d/%d vetores byte-identicos\n%!" (!total - !failed) !total

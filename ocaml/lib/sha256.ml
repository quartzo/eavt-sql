(* sha256.ml — FIPS 180-4 SHA-256, hand-rolled (zero deps; vectors in
   test/test.ml pin the padding boundaries 55/56/64 bytes).  Also the
   urlsafe-base64 tag used by the socio dedup key. *)

exception Error of string

let k =
  [| 0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl; 0x59f111f1l;
     0x923f82a4l; 0xab1c5ed5l; 0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l;
     0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l; 0xe49b69c1l; 0xefbe4786l;
     0x0fc19dc6l; 0x240ca1ccl; 0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
     0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l;
     0x06ca6351l; 0x14292967l; 0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l;
     0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l; 0xa2bfe8a1l; 0xa81a664bl;
     0xc24b8b70l; 0xc76c51a3l; 0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
     0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al;
     0x5b9cca4fl; 0x682e6ff3l; 0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
     0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l |]

let rotr x n = Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let process_block (h : int32 array) (block : string) off =
  let w = Array.make 64 0l in
  for i = 0 to 15 do
    let j = off + i * 4 in
    w.(i) <-
      Int32.logor
        (Int32.logor
           (Int32.shift_left (Int32.of_int (Char.code block.[j])) 24)
           (Int32.shift_left (Int32.of_int (Char.code block.[j + 1])) 16))
        (Int32.logor
           (Int32.shift_left (Int32.of_int (Char.code block.[j + 2])) 8)
           (Int32.of_int (Char.code block.[j + 3])))
  done;
  for i = 16 to 63 do
    let s0 = Int32.logxor (rotr w.(i - 15) 7) (Int32.logxor (rotr w.(i - 15) 18) (Int32.shift_right_logical w.(i - 15) 3)) in
    let s1 = Int32.logxor (rotr w.(i - 2) 17) (Int32.logxor (rotr w.(i - 2) 19) (Int32.shift_right_logical w.(i - 2) 10)) in
    w.(i) <- Int32.add w.(i - 16) (Int32.add s0 (Int32.add w.(i - 7) s1))
  done;
  let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) and d = ref h.(3) in
  let e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
  for i = 0 to 63 do
    let s1 = Int32.logxor (rotr !e 6) (Int32.logxor (rotr !e 11) (rotr !e 25)) in
    let ch = Int32.logxor (Int32.logand !e !f) (Int32.logand (Int32.lognot !e) !g) in
    let t1 = Int32.add !hh (Int32.add s1 (Int32.add (Int32.add ch k.(i)) w.(i))) in
    let s0 = Int32.logxor (rotr !a 2) (Int32.logxor (rotr !a 13) (rotr !a 22)) in
    let maj = Int32.logxor (Int32.logand !a !b) (Int32.logxor (Int32.logand !a !c) (Int32.logand !b !c)) in
    let t2 = Int32.add s0 maj in
    hh := !g;
    g := !f;
    f := !e;
    e := Int32.add !d t1;
    d := !c;
    c := !b;
    b := !a;
    a := Int32.add t1 t2
  done;
  h.(0) <- Int32.add h.(0) !a;
  h.(1) <- Int32.add h.(1) !b;
  h.(2) <- Int32.add h.(2) !c;
  h.(3) <- Int32.add h.(3) !d;
  h.(4) <- Int32.add h.(4) !e;
  h.(5) <- Int32.add h.(5) !f;
  h.(6) <- Int32.add h.(6) !g;
  h.(7) <- Int32.add h.(7) !hh

let digest (msg : string) : string =
  let h =
    [| 0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al; 0x510e527fl; 0x9b05688cl;
       0x1f83d9abl; 0x5be0cd19l |]
  in
  let len = String.length msg in
  let bit_len = Int64.of_int (len * 8) in
  let padded_len = ((len + 8) / 64 + 1) * 64 in
  let buf = Buffer.create padded_len in
  Buffer.add_string buf msg;
  Buffer.add_char buf '\x80';
  while Buffer.length buf mod 64 <> 56 do
    Buffer.add_char buf '\x00'
  done;
  for shift = 7 downto 0 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bit_len (shift * 8)) 0xffL)))
  done;
  let padded = Buffer.contents buf in
  let n_blocks = String.length padded / 64 in
  for b = 0 to n_blocks - 1 do
    process_block h padded (b * 64)
  done;
  let out = Bytes.create 32 in
  Array.iteri
    (fun i v ->
      Bytes.set out (i * 4) (Char.chr (Int32.to_int (Int32.shift_right_logical v 24) land 0xff));
      Bytes.set out (i * 4 + 1) (Char.chr (Int32.to_int (Int32.shift_right_logical v 16) land 0xff));
      Bytes.set out (i * 4 + 2) (Char.chr (Int32.to_int (Int32.shift_right_logical v 8) land 0xff));
      Bytes.set out (i * 4 + 3) (Char.chr (Int32.to_int v land 0xff)))
    h;
  Bytes.to_string out

let hex (d : string) : string =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq d)))

(* urlsafe base64 without padding — the socio tag takes the first 6
   chars of urlsafe_b64encode(digest), which never hits padding for a
   32-byte digest *)
let b64url (s : string) : string =
  let std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let buf = Buffer.create ((n + 2) / 3 * 4) in
  let enc3 x =
    Buffer.add_char buf std.[(x lsr 18) land 63];
    Buffer.add_char buf std.[(x lsr 12) land 63];
    Buffer.add_char buf std.[(x lsr 6) land 63];
    Buffer.add_char buf std.[x land 63]
  in
  let i = ref 0 in
  while !i + 2 < n do
    enc3 (Char.code s.[!i] lsl 16 lor Char.code s.[!i + 1] lsl 8 lor Char.code s.[!i + 2]);
    i := !i + 3
  done;
  (match n - !i with
   | 1 -> enc3 ((Char.code s.[!i] lsl 16) land 0xFC0000)
   | 2 -> enc3 ((Char.code s.[!i] lsl 16) lor ((Char.code s.[!i + 1] lsl 8) land 0x00FC00))
   | _ -> ());
  let b = Buffer.contents buf in
  String.map (fun c -> if c = '+' then '-' else if c = '/' then '_' else c) b

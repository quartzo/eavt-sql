(* edn.ml — EDN reader for the Datomic-style tx-data subset, mirroring
   nim_edn/edn.nim:
     vectors [..], lists (..), keywords :ns/name (kwval WITHOUT the
     leading colon), symbols, ?vars, strings, ints (negative tempids),
     floats, true/false/nil, `_`.  Commas are whitespace.  Maps {..} and
     sets #{..} are rejected.  Fail-loud with position. *)

exception Edn_error of string

type t =
  | Int of int64
  | Float of float
  | Str of string
  | Bool of bool
  | Nil
  | Keyword of string
  | Symbol of string
  | List of t list

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = ','

let skip_ws (s : string) pos =
  let rec loop pos = if pos < String.length s && is_ws s.[pos] then loop (pos + 1) else pos in
  loop pos

let is_delim c =
  is_ws c || c = '(' || c = ')' || c = '[' || c = ']' || c = '{' || c = '}' || c = '"'

let is_digit c = c >= '0' && c <= '9'

let parse_string (s : string) pos : string * int =
  (* pos sits on the opening quote *)
  let len = String.length s in
  let buf = Buffer.create 16 in
  let rec loop pos =
    if pos >= len then raise (Edn_error "edn: unterminated string");
    match s.[pos] with
    | '"' -> (Buffer.contents buf, pos + 1)
    | '\\' ->
      if pos + 1 >= len then raise (Edn_error "edn: unterminated escape at end of input");
      (match s.[pos + 1] with
       | 'n' -> Buffer.add_char buf '\n'; loop (pos + 2)
       | 't' -> Buffer.add_char buf '\t'; loop (pos + 2)
       | 'r' -> Buffer.add_char buf '\r'; loop (pos + 2)
       | '"' -> Buffer.add_char buf '"'; loop (pos + 2)
       | '\\' -> Buffer.add_char buf '\\'; loop (pos + 2)
       | esc ->
         raise (Edn_error
                  (Printf.sprintf "edn: unsupported escape \\%c at pos %d" esc pos)))
    | c -> Buffer.add_char buf c; loop (pos + 1)
  in
  loop (pos + 1)

let rec parse_value (s : string) (pos : int) : t * int =
  let pos = skip_ws s pos in
  let len = String.length s in
  if pos >= len then raise (Edn_error "edn: unexpected end of input");
  match s.[pos] with
  | '[' ->
    let rec loop pos acc =
      let pos = skip_ws s pos in
      if pos >= len then raise (Edn_error "edn: unterminated vector")
      else if s.[pos] = ']' then (List (List.rev acc), pos + 1)
      else
        let (v, pos) = parse_value s pos in
        loop pos (v :: acc)
    in
    loop (pos + 1) []
  | '(' ->
    let rec loop pos acc =
      let pos = skip_ws s pos in
      if pos >= len then raise (Edn_error "edn: unterminated list")
      else if s.[pos] = ')' then (List (List.rev acc), pos + 1)
      else
        let (v, pos) = parse_value s pos in
        loop pos (v :: acc)
    in
    loop (pos + 1) []
  | '{' -> raise (Edn_error (Printf.sprintf "edn: maps not supported at pos %d" pos))
  | '#' ->
    if pos + 1 < len && s.[pos + 1] = '{' then
      raise (Edn_error (Printf.sprintf "edn: sets not supported at pos %d" pos))
    else
      raise (Edn_error
               (Printf.sprintf "edn: unsupported dispatch #%c at pos %d"
                  (if pos + 1 < len then s.[pos + 1] else '?') pos))
  | '"' ->
    let (str, pos) = parse_string s pos in
    (Str str, pos)
  | _ ->
    let start = pos in
    let rec scan pos =
      if pos < len && not (is_delim s.[pos]) then scan (pos + 1) else pos
    in
    let stop = scan pos in
    if stop = start then
      raise (Edn_error (Printf.sprintf "edn: empty atom at pos %d" start));
    let atom = String.sub s start (stop - start) in
    let v =
      match atom with
      | "nil" -> Nil
      | "true" -> Bool true
      | "false" -> Bool false
      | "_" -> Symbol "_"
      | ":" -> raise (Edn_error (Printf.sprintf "edn: bare ':' at pos %d" start))
      | a when a.[0] = ':' -> Keyword (String.sub a 1 (String.length a - 1))
      | a when is_digit a.[0] || ((a.[0] = '-' || a.[0] = '+') && String.length a > 1 && is_digit a.[1]) ->
        (try Int (Int64.of_string a)
         with Failure _ ->
           (try Float (float_of_string a)
            with Failure _ -> Symbol a))
      | a ->
        (try
           (* float only when plausibly numeric — keeps nan/inf as symbols *)
           let has_digit =
             String.exists (fun c -> is_digit c) a
           in
           if has_digit then Float (float_of_string a) else Symbol a
         with Failure _ -> Symbol a)
    in
    (v, stop)

let read_edn (s : string) : t =
  let (v, pos) = parse_value s 0 in
  let pos = skip_ws s pos in
  if pos <> String.length s then
    raise (Edn_error (Printf.sprintf "edn: trailing content at pos %d" pos));
  v

let read_edn_vector (s : string) : t list =
  let pos = skip_ws s 0 in
  let len = String.length s in
  if pos >= len || s.[pos] <> '[' then
    raise (Edn_error
             (Printf.sprintf "edn: expected tx-data vector, got: %s"
                (if pos < len then String.make 1 s.[pos] else "<eof>")));
  let (elems, _) = parse_value s pos in
  match elems with
  | List xs -> xs
  | _ -> assert false

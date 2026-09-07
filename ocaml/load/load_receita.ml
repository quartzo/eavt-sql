(* load_receita.ml — port of py_eavt/examples/load_receita_edn.py:
   load Receita Federal CNPJ data via EDN tx-data + Datalog through the
   query server.  Faithful to the Python loader, including the
   single-part-per-table coverage (find_zip takes the first match) and
   the batching/ref-tempid mechanics.  All field bytes are latin-1 and
   are converted to UTF-8 at the wire boundary, like Python's
   TextIOWrapper(latin-1) → msgpack UTF-8 encode. *)

open Eavt_lib

let default_data_dir = "/home/fabio/dev/dagster_flows/tests_data/receita_zip"
let zero_date = "00000000"

(* ── formatting helpers ────────────────────────────────────────────── *)

let commas (n : int) : string =
  let neg = n < 0 in
  let s = string_of_int (abs n) in
  let len = String.length s in
  let buf = Buffer.create (len + len / 3) in
  String.iteri
    (fun i c ->
      Buffer.add_char buf c;
      if (len - i - 1) mod 3 = 0 && i < len - 1 then Buffer.add_char buf ',')
    s;
  (if neg then "-" else "") ^ Buffer.contents buf

let is_digit c = c >= '0' && c <= '9'
let all_digits s = String.for_all is_digit s

let zfill (s : string) (w : int) =
  if String.length s >= w then s else String.make (w - String.length s) '0' ^ s

let now () = Unix.gettimeofday ()

(* ── EDN tx helpers ────────────────────────────────────────────────── *)

let kw name = Edn.Keyword name

let op_add (e : int) (attr : string) (v : Edn.t) : Edn.t =
  Edn.List [ kw "db/add"; Edn.Int (Int64.of_int e); kw attr; v ]

let tx_flush (client : Client.t) (ops : Edn.t Dynarray.t) : unit =
  if Dynarray.length ops > 0 then (
    ignore (Client.tx client (Dynarray.to_list ops));
    Dynarray.clear ops)

(* ── RefTids ───────────────────────────────────────────────────────── *)

type reftids = { mutable next : int; by_key : (string * string, int) Hashtbl.t }

let reftids_new () = { next = -1; by_key = Hashtbl.create 64 }

let fresh (r : reftids) : int =
  let tid = r.next in
  r.next <- tid - 1;
  tid

let ref_ (r : reftids) (ops : Edn.t Dynarray.t) (anchor_attr : string) (code : string) : int =
  match Hashtbl.find_opt r.by_key (anchor_attr, code) with
  | Some tid -> tid
  | None ->
    let tid = fresh r in
    Hashtbl.add r.by_key (anchor_attr, code) tid;
    Dynarray.add_last ops (op_add tid anchor_attr (Edn.Str (Latin1.to_utf8 code)));
    tid

(* ── schema ────────────────────────────────────────────────────────── *)

let schema_attrs =
  [ ("cnae/codigo", "string", true, true); ("cnae/descricao", "string", false, false);
    ("municipio/codigo", "string", true, true); ("municipio/nome", "string", false, false);
    ("natureza/codigo", "string", true, true); ("natureza/descricao", "string", false, false);
    ("qualificacao/codigo", "string", true, true);
    ("qualificacao/descricao", "string", false, false);
    ("pais/codigo", "string", true, true); ("pais/nome", "string", false, false);
    ("motivo/codigo", "string", true, true); ("motivo/descricao", "string", false, false);
    ("empresa/cnpj_base", "string", false, true);
    ("empresa/razao_social", "string", false, false);
    ("empresa/natureza_juridica", "ref", false, false);
    ("empresa/qualificacao_resp", "ref", false, false);
    ("empresa/capital_social", "float", false, false);
    ("empresa/porte", "string", false, false);
    ("empresa/optante_simples", "string", false, false);
    ("empresa/data_opcao_simples", "string", false, false);
    ("empresa/data_exclusao_simples", "string", false, false);
    ("empresa/optante_mei", "string", false, false);
    ("empresa/data_opcao_mei", "string", false, false);
    ("empresa/data_exclusao_mei", "string", false, false);
    ("estab/cnpj_completo", "string", false, true);
    ("estab/empresa", "ref", false, false);
    ("estab/matriz_filial", "string", false, false);
    ("estab/nome_fantasia", "string", false, false);
    ("estab/situacao", "string", false, false);
    ("estab/data_situacao", "string", false, false);
    ("estab/motivo", "ref", false, false);
    ("estab/pais", "ref", false, false);
    ("estab/data_inicio_ativ", "string", false, false);
    ("estab/cnae_principal", "ref", false, false);
    ("estab/cnae_secundario", "ref", true, false);
    ("estab/tipo_logradouro", "string", false, false);
    ("estab/logradouro", "string", false, false);
    ("estab/numero", "string", false, false);
    ("estab/complemento", "string", false, false);
    ("estab/bairro", "string", false, false);
    ("estab/cep", "string", false, false);
    ("estab/uf", "string", false, false);
    ("estab/municipio", "ref", false, false);
    ("estab/ddd1", "string", false, false);
    ("estab/telefone1", "string", false, false);
    ("estab/ddd2", "string", false, false);
    ("estab/telefone2", "string", false, false);
    ("estab/email", "string", false, false);
    ("socio/empresa", "ref", false, false);
    ("socio/pessoa", "ref", false, false);
    ("socio/tipo_pessoa", "string", false, false);
    ("socio/nome", "string", false, false);
    ("socio/cpf_cnpj", "string", false, false);
    ("socio/chave", "string", false, true);
    ("socio/chave_rel", "string", false, true);
    ("socio/qualificacao", "ref", false, false);
    ("socio/data_entrada", "string", false, false);
    ("socio/pais", "ref", false, false);
    ("socio/faixa_etaria", "string", false, false) ]

let declare_schema (client : Client.t) : unit =
  let ops = Dynarray.create () in
  List.iteri
    (fun i (name, vt, many, unique) ->
      let eid = 1000 + i in
      Dynarray.add_last ops (op_add eid "db/ident" (kw name));
      Dynarray.add_last ops (op_add eid "db/valueType" (kw ("db.type/" ^ vt)));
      Dynarray.add_last ops
        (op_add eid "db/cardinality"
           (kw (if many then "db.cardinality/many" else "db.cardinality/one")));
      if unique then Dynarray.add_last ops (op_add eid "db/unique" (kw "db.unique/identity")))
    schema_attrs;
  let t0 = now () in
  tx_flush client ops;
  let elapsed = now () -. t0 in
  Printf.printf "  declared %d attributes in %.1fs\n%!" (List.length schema_attrs) elapsed

(* ── rows from zip (interprocess: unzip streams on its own core) ───── *)

type rows = { stream : Zipsrc.stream; csv : Csv.t }

let open_rows (zpath : string) : rows =
  let stream = Zipsrc.open_zip zpath in
  let fd = Unix.descr_of_in_channel stream.Zipsrc.ic in
  { stream; csv = Csv.create fd }

let next_row (r : rows) : string list option = Csv.next_row r.csv

let close_rows (r : rows) : unit = Zipsrc.finish r.stream

(* ── lookups ───────────────────────────────────────────────────────── *)

let lookups =
  [ ("Cnaes", "cnae", "descricao"); ("Municipios", "municipio", "nome");
    ("Naturezas", "natureza", "descricao"); ("Qualificacoes", "qualificacao", "descricao");
    ("Paises", "pais", "nome"); ("Motivos", "motivo", "descricao") ]

let load_lookups (client : Client.t) (data_dir : string) (batch_size : int) : unit =
  List.iter
    (fun (zip_prefix, prefix, desc_attr) ->
      let zpath = Zipsrc.find_zip data_dir zip_prefix in
      let ops = Dynarray.create () in
      let total = ref 0 in
      let row_in_tx = ref 0 in
      let t0 = now () in
      let r = open_rows zpath in
      let rec loop () =
        match next_row r with
        | None -> ()
        | Some row ->
          if List.length row >= 2 && List.nth row 0 <> "" then begin
            let tid = -(!row_in_tx + 1) in
            Dynarray.add_last ops (op_add tid (prefix ^ "/codigo") (Edn.Str (Latin1.to_utf8 (List.nth row 0))));
            let desc = List.nth row 1 in
            if desc <> "" then
              Dynarray.add_last ops (op_add tid (prefix ^ "/" ^ desc_attr) (Edn.Str (Latin1.to_utf8 desc)));
            incr total;
            incr row_in_tx;
            if Dynarray.length ops >= batch_size * 2 then begin
              tx_flush client ops;
              row_in_tx := 0
            end
          end;
          loop ()
      in
      loop ();
      tx_flush client ops;
      close_rows r;
      let elapsed = now () -. t0 in
      Printf.printf "  %s: %s entries in %.1fs (%s/s)\n%!" prefix (commas !total) elapsed
        (commas (int_of_float (float_of_int !total /. max elapsed 0.001))))
    lookups

(* ── empresas ──────────────────────────────────────────────────────── *)

let load_empresas (client : Client.t) (data_dir : string) (n : int) (batch_size : int) : int =
  let zpath = Zipsrc.find_zip data_dir "Empresas0" in
  let ops = Dynarray.create () in
  let total = ref 0 in
  let refs = ref (reftids_new ()) in
  let t0 = now () in
  let r = open_rows zpath in
  let rec loop () =
    if !total >= n then ()
    else
      match next_row r with
      | None -> ()
      | Some row ->
        if List.length row >= 6 then begin
          let cnpj = List.nth row 0 in
          if String.length cnpj = 8 && all_digits cnpj then begin
            let tid = fresh !refs in
            Dynarray.add_last ops (op_add tid "empresa/cnpj_base" (Edn.Str (Latin1.to_utf8 cnpj)));
            let rs = List.nth row 1 in
            if rs <> "" then
              Dynarray.add_last ops (op_add tid "empresa/razao_social" (Edn.Str (Latin1.to_utf8 rs)));
            let nat = List.nth row 2 in
            if nat <> "" then
              Dynarray.add_last ops
                (op_add tid "empresa/natureza_juridica"
                   (Edn.Int (Int64.of_int (ref_ !refs ops "natureza/codigo" nat))));
            let qual = List.nth row 3 in
            if qual <> "" then
              Dynarray.add_last ops
                (op_add tid "empresa/qualificacao_resp"
                   (Edn.Int (Int64.of_int (ref_ !refs ops "qualificacao/codigo" qual))));
            let cap = List.nth row 4 in
            if cap <> "" then begin
              let cap = String.map (fun c -> if c = ',' then '.' else c) cap in
              Dynarray.add_last ops (op_add tid "empresa/capital_social" (Edn.Float (float_of_string cap)))
            end;
            let porte = List.nth row 5 in
            if porte <> "" then
              Dynarray.add_last ops (op_add tid "empresa/porte" (Edn.Str (Latin1.to_utf8 porte)));
            incr total;
            if !total mod batch_size = 0 then begin
              tx_flush client ops;
              refs := reftids_new ();
              let elapsed = now () -. t0 in
              Printf.printf "    %10s empresas  %7.1fs  (%s/s)\n%!" (commas !total) elapsed
                (commas (int_of_float (float_of_int !total /. elapsed)))
            end
          end
        end;
        loop ()
  in
  loop ();
  if Dynarray.length ops > 0 then tx_flush client ops;
  close_rows r;
  let elapsed = now () -. t0 in
  Printf.printf "  empresas: %s in %.1fs (%s/s)\n%!" (commas !total) elapsed
    (commas (int_of_float (float_of_int !total /. max elapsed 0.001)));
  !total

(* ── simples ───────────────────────────────────────────────────────── *)

let merge_simples (client : Client.t) (data_dir : string) (batch_size : int) (max_rows : int) :
    int * int =
  let zpath = Zipsrc.find_zip data_dir "Simples" in
  let matched = ref 0 in
  let pending = ref 0 in
  let scanned = ref 0 in
  let ops = Dynarray.create () in
  let t0 = now () in
  let r = open_rows zpath in
  let rec loop () =
    if max_rows > 0 && !matched >= max_rows then ()
    else
      match next_row r with
      | None -> ()
      | Some row ->
        incr scanned;
        if !scanned mod 1_000_000 = 0 then begin
          let elapsed = now () -. t0 in
          Printf.printf "    scanned %s, matched %s  (%.1fs)\n%!" (commas !scanned)
            (commas !matched) elapsed
        end;
        if List.length row >= 7 then begin
          let sets = ref [] in
          if List.nth row 1 <> "" then sets := ("empresa/optante_simples", List.nth row 1) :: !sets;
          if List.nth row 2 <> "" && List.nth row 2 <> zero_date then
            sets := ("empresa/data_opcao_simples", List.nth row 2) :: !sets;
          if List.nth row 3 <> "" && List.nth row 3 <> zero_date then
            sets := ("empresa/data_exclusao_simples", List.nth row 3) :: !sets;
          if List.nth row 4 <> "" then sets := ("empresa/optante_mei", List.nth row 4) :: !sets;
          if List.nth row 5 <> "" && List.nth row 5 <> zero_date then
            sets := ("empresa/data_opcao_mei", List.nth row 5) :: !sets;
          if List.nth row 6 <> "" && List.nth row 6 <> zero_date then
            sets := ("empresa/data_exclusao_mei", List.nth row 6) :: !sets;
          if !sets <> [] then begin
            let tid = -(!pending + 1) in
            Dynarray.add_last ops (op_add tid "empresa/cnpj_base" (Edn.Str (Latin1.to_utf8 (List.nth row 0))));
            List.iter
              (fun (attr, v) -> Dynarray.add_last ops (op_add tid attr (Edn.Str (Latin1.to_utf8 v))))
              (List.rev !sets);
            incr pending;
            if Dynarray.length ops >= batch_size * 2 then begin
              tx_flush client ops;
              matched := !matched + !pending;
              pending := 0
            end
          end
        end;
        loop ()
  in
  loop ();
  if Dynarray.length ops > 0 then begin
    tx_flush client ops;
    matched := !matched + !pending
  end;
  close_rows r;
  let elapsed = now () -. t0 in
  Printf.printf "  simples: %s matched (scanned %s) in %.1fs (%s/s)\n%!" (commas !matched)
    (commas !scanned) elapsed
    (commas (int_of_float (float_of_int !matched /. max elapsed 0.001)));
  (!matched, !scanned)

(* ── estabelecimentos ──────────────────────────────────────────────── *)

let estab_str_attrs =
  [ (0, "estab/cnpj_completo"); (3, "estab/matriz_filial"); (4, "estab/nome_fantasia");
    (5, "estab.situacao"); (6, "estab.data_situacao"); (10, "estab.data_inicio_ativ");
    (13, "estab/tipo_logradouro"); (14, "estab/logradouro"); (15, "estab/numero");
    (16, "estab/complemento"); (17, "estab/bairro"); (18, "estab/cep"); (19, "estab/uf");
    (21, "estab/ddd1"); (22, "estab/telefone1"); (23, "estab/ddd2"); (24, "estab/telefone2");
    (27, "estab/email") ]

let estab_ref_attrs =
  [ (0, "estab.empresa", "empresa/cnpj_base"); (7, "estab.motivo", "motivo/codigo");
    (9, "estab.pais", "pais/codigo"); (11, "estab.cnae_principal", "cnae/codigo");
    (20, "estab.municipio", "municipio/codigo") ]

let nth (row : string list) (i : int) : string = try List.nth row i with _ -> ""

let flush_estab_batch (client : Client.t) (batch : string list list) : unit =
  let ops = Dynarray.create () in
  let refs = reftids_new () in
  List.iter
    (fun row ->
      let cnpj_full = nth row 0 ^ zfill (nth row 1) 4 ^ zfill (nth row 2) 2 in
      let estab_tid = fresh refs in
      Dynarray.add_last ops (op_add estab_tid "estab/cnpj_completo" (Edn.Str (Latin1.to_utf8 cnpj_full)));
      let etid = ref_ refs ops "empresa/cnpj_base" (nth row 0) in
      Dynarray.add_last ops (op_add estab_tid "estab/empresa" (Edn.Int (Int64.of_int etid)));
      List.iter
        (fun (idx, attr) ->
          if idx <> 0 && nth row idx <> "" then
            Dynarray.add_last ops (op_add estab_tid attr (Edn.Str (Latin1.to_utf8 (nth row idx)))))
        estab_str_attrs;
      List.iter
        (fun (idx, attr, uattr) ->
          let code = nth row idx in
          if code <> "" && attr <> "estab.empresa" then
            Dynarray.add_last ops
              (op_add estab_tid attr (Edn.Int (Int64.of_int (ref_ refs ops uattr code)))))
        estab_ref_attrs;
      let cnaes = nth row 12 in
      if cnaes <> "" then
        String.split_on_char ',' cnaes
        |> List.iter (fun code ->
               let code = String.trim code in
               if code <> "" then
                 Dynarray.add_last ops
                   (op_add estab_tid "estab/cnae_secundario"
                      (Edn.Int (Int64.of_int (ref_ refs ops "cnae/codigo" code))))))
    batch;
  tx_flush client ops

let load_estabs_bulk (client : Client.t) (data_dir : string) (max_rows : int) (batch_size : int) :
    int * int =
  let zpath = Zipsrc.find_zip data_dir "Estabelecimentos0" in
  let saved = ref 0 in
  let scanned = ref 0 in
  let batch = ref [] in
  let t0 = now () in
  let r = open_rows zpath in
  let rec loop () =
    match next_row r with
    | None -> ()
    | Some row ->
      incr scanned;
      if List.length row >= 30 && String.length (nth row 0) = 8 && all_digits (nth row 0) then
        batch := row :: !batch;
      if List.length !batch >= batch_size then begin
        flush_estab_batch client (List.rev !batch);
        saved := !saved + List.length !batch;
        batch := [];
        (* faithful to the Python loader: with max_rows=0 the first
           full batch already satisfies saved >= max_rows and stops *)
        if !saved >= max_rows then () else loop ()
      end
      else loop ()
  in
  loop ();
  if !batch <> [] && !saved < max_rows then begin
    flush_estab_batch client (List.rev !batch);
    saved := !saved + List.length !batch
  end;
  close_rows r;
  let elapsed = now () -. t0 in
  Printf.printf "  estabs(tx): %s linhas gravadas (scanned %s) in %.1fs\n%!" (commas !saved)
    (commas !scanned) elapsed;
  (!saved, !scanned)

(* ── socios ────────────────────────────────────────────────────────── *)

let upper_latin1 (s : string) : string =
  String.map
    (fun c ->
      let b = Char.code c in
      if b >= 0xE0 && b <= 0xFE && b <> 0xF7 then Char.chr (b - 0x20) else c)
    s

let collapse_ws (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let pending = ref false in
  String.iter
    (fun c ->
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' then pending := !pending || Buffer.length buf > 0
      else begin
        if !pending then (Buffer.add_char buf ' '; pending := false);
        Buffer.add_char buf c
      end)
    s;
  Buffer.contents buf

let socio_chave (cpf_cnpj : string) (nome : string) : string =
  let visible = String.concat "" (String.split_on_char '*' cpf_cnpj) in
  let norm = collapse_ws (upper_latin1 (String.trim nome)) in
  let digest = Sha256.digest (Latin1.to_utf8 norm) in
  let tag = String.sub (Sha256.b64url digest) 0 6 in
  visible ^ "-" ^ tag

let flush_socio_batch (client : Client.t) (batch : string list list) : unit =
  let ops = Dynarray.create () in
  let refs = reftids_new () in
  List.iter
    (fun row ->
      let chave = socio_chave (nth row 3) (nth row 2) in
      let pessoa_tid =
        if String.length chave < 4 then fresh refs else ref_ refs ops "socio/chave" chave
      in
      if nth row 1 <> "" then
        Dynarray.add_last ops (op_add pessoa_tid "socio/tipo_pessoa" (Edn.Str (Latin1.to_utf8 (nth row 1))));
      if nth row 2 <> "" then
        Dynarray.add_last ops (op_add pessoa_tid "socio/nome" (Edn.Str (Latin1.to_utf8 (nth row 2))));
      if nth row 3 <> "" then
        Dynarray.add_last ops (op_add pessoa_tid "socio/cpf_cnpj" (Edn.Str (Latin1.to_utf8 (nth row 3))));
      if nth row 6 <> "" then
        Dynarray.add_last ops
          (op_add pessoa_tid "socio/pais"
             (Edn.Int (Int64.of_int (ref_ refs ops "pais/codigo" (nth row 6)))));
      if nth row 10 <> "" then
        Dynarray.add_last ops (op_add pessoa_tid "socio/faixa_etaria" (Edn.Str (Latin1.to_utf8 (nth row 10))));
      let etid = ref_ refs ops "empresa/cnpj_base" (nth row 0) in
      let rel_tid =
        if String.length chave < 4 then fresh refs
        else ref_ refs ops "socio/chave_rel" (chave ^ "-" ^ nth row 0)
      in
      Dynarray.add_last ops (op_add rel_tid "socio/empresa" (Edn.Int (Int64.of_int etid)));
      Dynarray.add_last ops (op_add rel_tid "socio/pessoa" (Edn.Int (Int64.of_int pessoa_tid)));
      if nth row 4 <> "" then
        Dynarray.add_last ops
          (op_add rel_tid "socio/qualificacao"
             (Edn.Int (Int64.of_int (ref_ refs ops "qualificacao/codigo" (nth row 4)))));
      if nth row 5 <> "" && nth row 5 <> zero_date then
        Dynarray.add_last ops (op_add rel_tid "socio/data_entrada" (Edn.Str (Latin1.to_utf8 (nth row 5)))))
    batch;
  tx_flush client ops

let load_socios (client : Client.t) (data_dir : string) (batch_size : int) (max_scan : int) :
    int * int =
  let zpath = Zipsrc.find_zip data_dir "Socios0" in
  let batch = ref [] in
  let total = ref 0 in
  let scanned = ref 0 in
  let t0 = now () in
  let r = open_rows zpath in
  let rec loop () =
    if max_scan > 0 && !scanned > max_scan then ()
    else
      match next_row r with
      | None -> ()
      | Some row ->
        if List.length row >= 11 then begin
          let cnpj_base = nth row 0 in
          if String.length cnpj_base = 8 && all_digits cnpj_base then begin
            incr scanned;
            batch := row :: !batch;
            if List.length !batch >= batch_size then begin
              flush_socio_batch client (List.rev !batch);
              total := !total + List.length !batch;
              batch := []
            end
          end
        end;
        loop ()
  in
  loop ();
  if !batch <> [] then begin
    flush_socio_batch client (List.rev !batch);
    total := !total + List.length !batch
  end;
  close_rows r;
  let elapsed = now () -. t0 in
  Printf.printf "  socios: %s in %.1fs\n%!" (commas !total) elapsed;
  (!total, !scanned)

let edn_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      if c = '"' || c = '\\' then Buffer.add_char buf '\\';
      Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* ── demo probe ────────────────────────────────────────────────────── *)

let demo_only (client : Client.t) : int =
  let chunks =
    Client.datalog client
      "[:find ?cnpj ?rs :where [?e :empresa/cnpj_base ?cnpj] [?e :empresa/razao_social ?rs]]"
  in
  let all_rows = List.concat_map (fun c -> c.Client.rows) chunks in
  match all_rows with
  | [] -> print_endline "  (empty DB)"; 0
  | row0 :: _ ->
    let cnpj = List.nth row0 0 in
    let rs = List.nth row0 1 in
    let rs_short = if String.length rs > 40 then String.sub rs 0 40 else rs in
    Printf.printf "first empresa: cnpj=%s rs=\"%s\"\n%!" cnpj rs_short;
    let chunks =
      Client.datalog client
        (Printf.sprintf "[:find ?e :where [?e :empresa/cnpj_base \"%s\"]]" (edn_escape cnpj))
    in
    (match List.concat_map (fun c -> c.Client.rows) chunks with
     | r :: _ ->
       Printf.printf "eid lookup: %s\n%!" (List.nth r 0);
       let eid = List.nth r 0 in
       let chunks =
         Client.datalog client
           (Printf.sprintf
              "[:find ?fant :where [?e :estab/empresa %s] [?e :estab.nome_fantasia ?fant]]"
              eid)
       in
       let estabs = List.concat_map (fun c -> c.Client.rows) chunks in
       Printf.printf "estabs: %d\n%!" (List.length estabs)
     | [] -> print_endline "eid lookup: (none)");
    0

(* ── probe: first N cnpjs of Empresas0 → attrs, tab-separated ────────
   Nota: a engine ignora o campo "params" do datalog (query com param
   retorna o dataset global), então o probe embute o valor na query. *)

let probe (client : Client.t) (data_dir : string) (n : int) : unit =
  let zpath = Zipsrc.find_zip data_dir "Empresas0" in
  let r = open_rows zpath in
  let got = ref 0 in
  let rec loop () =
    if !got >= n then ()
    else
      match next_row r with
      | None -> ()
      | Some row ->
        if List.length row >= 6 && String.length (nth row 0) = 8 && all_digits (nth row 0) then begin
          let cnpj = nth row 0 in
          let q =
            Printf.sprintf
              "[:find ?rs ?cap :where [?e :empresa/cnpj_base \"%s\"] [?e :empresa/razao_social ?rs] [?e :empresa/capital_social ?cap]]"
              (edn_escape cnpj)
          in
          List.iter
            (fun c -> List.iter (fun row -> print_endline (String.concat "\t" (cnpj :: row))) c.Client.rows)
            (Client.datalog client q);
          incr got
        end;
        loop ()
  in
  loop ();
  close_rows r

(* ── main ──────────────────────────────────────────────────────────── *)

let usage =
  "Usage: load_receita [options]\n\
\  --n N               empresas to load (default 1000000)\n\
\  --data-dir DIR      receita zip dir (default " ^ default_data_dir ^ ")\n\
\  --sock PATH         query server socket (default auto-detect)\n\
\  --batch N           ops batch size (default 500)\n\
\  --demo-only         run the demo probe and exit\n\
\  --skip-simples      skip Simples merge\n\
\  --skip-estabs       skip Estabelecimentos0\n\
\  --skip-socios       skip Socios0\n\
\  --max-estabs N      stop estabs after N saved rows (0 = first batch, like Python)\n\
\  --max-socios N      stop socios after N scanned rows\n"

let () =
  let n = ref 1_000_000 in
  let data_dir = ref default_data_dir in
  let sock = ref "" in
  let batch = ref 500 in
  let demo = ref false in
  let skip_simples = ref false in
  let skip_estabs = ref false in
  let skip_socios = ref false in
  let max_estabs = ref 0 in
  let max_socios = ref 0 in
  let probe_n = ref 0 in
  let need_value flag rest =
    match rest with
    | v :: rest' -> (v, rest')
    | [] -> prerr_endline ("Error: " ^ flag ^ " requires an argument"); exit 1
  in
  let rec parse = function
    | [] -> ()
    | arg :: rest ->
      (match arg with
       | "--help" | "-h" -> print_string usage; exit 0
       | "--n" -> let v, rest' = need_value arg rest in n := int_of_string v; parse rest'
       | "--data-dir" -> let v, rest' = need_value arg rest in data_dir := v; parse rest'
       | "--sock" -> let v, rest' = need_value arg rest in sock := v; parse rest'
       | "--batch" -> let v, rest' = need_value arg rest in batch := int_of_string v; parse rest'
       | "--demo-only" -> demo := true; parse rest
       | "--skip-simples" -> skip_simples := true; parse rest
       | "--skip-estabs" -> skip_estabs := true; parse rest
       | "--skip-socios" -> skip_socios := true; parse rest
       | "--max-estabs" -> let v, rest' = need_value arg rest in max_estabs := int_of_string v; parse rest'
       | "--max-socios" -> let v, rest' = need_value arg rest in max_socios := int_of_string v; parse rest'
       | "--probe" -> let v, rest' = need_value arg rest in probe_n := int_of_string v; parse rest'
       | other -> prerr_endline ("Unknown option: " ^ other); prerr_string usage; exit 1)
  in
  parse (List.tl (Array.to_list Sys.argv));
  let sock_path = if !sock = "" then Client.socket_path () else !sock in
  let client =
    match Client.try_connect sock_path with
    | Some c -> c
    | None -> prerr_endline ("Error: cannot connect to " ^ sock_path); exit 1
  in
  if !probe_n = 0 && not !demo then print_endline "Connected to query server";
  try
    if !demo then exit (demo_only client);
    if !probe_n > 0 then begin
      probe client !data_dir !probe_n;
      Client.close client;
      exit 0
    end;
    print_endline "== Declaring schema (tx schema-as-data) ==";
    declare_schema client;
    Printf.printf "\n== Lookups (data: %s) ==\n%!" !data_dir;
    load_lookups client !data_dir !batch;
    Printf.printf "\n== Empresas0 (first %s) ==\n%!" (commas !n);
    let _ = load_empresas client !data_dir !n !batch in
    if not !skip_simples then begin
      print_endline "\n== Simples (merge via tx upsert) ==";
      let _ = merge_simples client !data_dir !batch 0 in
      ()
    end;
    print_endline "\n== Estabelecimentos0 ==";
    if not !skip_estabs then ignore (load_estabs_bulk client !data_dir !max_estabs !batch);
    print_endline "\n== Socios0 ==";
    if not !skip_socios then ignore (load_socios client !data_dir !batch !max_socios);
    Client.close client
  with
  | Client.Server_error m -> prerr_endline ("Error: " ^ m); exit 1
  | Failure m -> prerr_endline ("Error: " ^ m); exit 1
  | Sys_error m -> prerr_endline ("Error: " ^ m); exit 1

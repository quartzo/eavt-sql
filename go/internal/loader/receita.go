// Package loader bulk-loads the Receita Federal CNPJ open data into the EAVT
// stack over the wire tx protocol.  Port of the reference `load_receita` loader
// (py_eavt/examples/load_receita_edn.py): schema as tx-data, then
// lookups / empresas / simples / estabelecimentos / socios, batched into `tx`
// requests.  Refs and get-or-create use negative tempids plus the unique-attr
// upsert (so re-adding a known key merges into the existing entity).
package loader

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/base64"
	"encoding/csv"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"eavt-go/internal/client"
	"eavt-go/internal/edn"
)

// DefaultDataDir is the reference receita zip directory.
const DefaultDataDir = "/home/fabio/dev/dagster_flows/tests_data/receita_zip"

const zeroDate = "00000000"

// Txer is the tx surface the loader needs (implemented by *client.Client).
type Txer interface {
	TxData(ops []edn.Value) error
}

// Opts configures a Receita load.
type Opts struct {
	DataDir     string
	N           int // empresas to load
	Batch       int // ops per tx flush
	SkipSimples bool
	SkipEstabs  bool
	SkipSocios  bool
	MaxEstabs   int // stop estabs after N saved (0 = first batch, like Python)
	MaxSocios   int // stop socios after N scanned (0 = unlimited)
}

// ── latin-1 → UTF-8 ──────────────────────────────────────────────────────

func latin1ToUTF8(s string) string {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) * 2)
	for i := 0; i < len(s); i++ {
		b.WriteRune(rune(s[i]))
	}
	return b.String()
}

// ── zip / csv row streaming ──────────────────────────────────────────────

// findZip locates a table's zip.  Three conventions are tried in order, so
// both the `Name__TIMESTAMP.zip` layout of the reference loaders and a plain
// `Name.zip` layout work:
//
//  1. exact        Name.zip
//  2. underscore   Name__*.zip (the reference loaders' pattern)
//  3. prefix       Name*.zip   (first sorted match)
func findZip(dir, prefix string) (string, error) {
	patterns := []string{
		filepath.Join(dir, prefix+".zip"),
		filepath.Join(dir, prefix+"__*.zip"),
		filepath.Join(dir, prefix+"*.zip"),
	}
	for _, pat := range patterns {
		matches, err := filepath.Glob(pat)
		if err != nil {
			return "", err
		}
		sort.Strings(matches)
		if len(matches) > 0 {
			return matches[0], nil
		}
	}
	return "", fmt.Errorf("no zip matching %s.zip / %s__*.zip in %s", prefix, prefix, dir)
}

type rowReader struct {
	zrc io.ReadCloser
	zf  *zip.ReadCloser
	cr  *csv.Reader
}

func openRows(zpath string) (*rowReader, error) {
	zf, err := zip.OpenReader(zpath)
	if err != nil {
		return nil, err
	}
	if len(zf.File) == 0 {
		zf.Close()
		return nil, fmt.Errorf("empty zip: %s", zpath)
	}
	zrc, err := zf.File[0].Open()
	if err != nil {
		zf.Close()
		return nil, err
	}
	cr := csv.NewReader(zrc)
	cr.Comma = ';'
	cr.FieldsPerRecord = -1
	cr.LazyQuotes = true
	return &rowReader{zrc: zrc, zf: zf, cr: cr}, nil
}

func (r *rowReader) Next() ([]string, error) {
	rec, err := r.cr.Read()
	if err != nil {
		return nil, err
	}
	for i := range rec {
		rec[i] = latin1ToUTF8(rec[i])
	}
	return rec, nil
}

func (r *rowReader) Close() {
	if r.zrc != nil {
		r.zrc.Close()
	}
	if r.zf != nil {
		r.zf.Close()
	}
}

// ── tx helpers ───────────────────────────────────────────────────────────

func addOp(eid int64, attr string, v edn.Value) edn.Value {
	return edn.List{edn.Keyword("db/add"), edn.Int(eid), edn.Keyword(attr), v}
}

func flush(c Txer, ops *[]edn.Value) error {
	if len(*ops) == 0 {
		return nil
	}
	err := c.TxData(*ops)
	*ops = (*ops)[:0]
	return err
}

// refTids dedups get-or-create ops within one tx batch (negative tempids).
type refTids struct {
	next  int64
	byKey map[[2]string]int64
}

func newRefTids() *refTids { return &refTids{next: -1, byKey: map[[2]string]int64{}} }

func (r *refTids) fresh() int64 {
	t := r.next
	r.next--
	return t
}

func (r *refTids) ref(ops *[]edn.Value, anchor, code string) int64 {
	key := [2]string{anchor, code}
	if t, ok := r.byKey[key]; ok {
		return t
	}
	t := r.fresh()
	r.byKey[key] = t
	*ops = append(*ops, addOp(t, anchor, edn.Str(code)))
	return t
}

// ── schema ───────────────────────────────────────────────────────────────

type attrSpec struct {
	name   string
	vt     string
	many   bool
	unique bool
}

var schemaAttrs = []attrSpec{
	{"cnae/codigo", "string", false, true}, {"cnae/descricao", "string", false, false},
	{"municipio/codigo", "string", false, true}, {"municipio/nome", "string", false, false},
	{"natureza/codigo", "string", false, true}, {"natureza/descricao", "string", false, false},
	{"qualificacao/codigo", "string", false, true}, {"qualificacao/descricao", "string", false, false},
	{"pais/codigo", "string", false, true}, {"pais/nome", "string", false, false},
	{"motivo/codigo", "string", false, true}, {"motivo/descricao", "string", false, false},
	{"empresa/cnpj_base", "string", false, true},
	{"empresa/razao_social", "string", false, false},
	{"empresa/natureza_juridica", "ref", false, false},
	{"empresa/qualificacao_resp", "ref", false, false},
	{"empresa/capital_social", "float", false, false},
	{"empresa/porte", "string", false, false},
	{"empresa/optante_simples", "string", false, false},
	{"empresa/data_opcao_simples", "string", false, false},
	{"empresa/data_exclusao_simples", "string", false, false},
	{"empresa/optante_mei", "string", false, false},
	{"empresa/data_opcao_mei", "string", false, false},
	{"empresa/data_exclusao_mei", "string", false, false},
	{"estab/cnpj_completo", "string", false, true},
	{"estab/empresa", "ref", false, false},
	{"estab/matriz_filial", "string", false, false},
	{"estab/nome_fantasia", "string", false, false},
	{"estab/situacao", "string", false, false},
	{"estab/data_situacao", "string", false, false},
	{"estab/motivo", "ref", false, false},
	{"estab/pais", "ref", false, false},
	{"estab/data_inicio_ativ", "string", false, false},
	{"estab/cnae_principal", "ref", false, false},
	{"estab/cnae_secundario", "ref", true, false},
	{"estab/tipo_logradouro", "string", false, false},
	{"estab/logradouro", "string", false, false},
	{"estab/numero", "string", false, false},
	{"estab/complemento", "string", false, false},
	{"estab/bairro", "string", false, false},
	{"estab/cep", "string", false, false},
	{"estab/uf", "string", false, false},
	{"estab/municipio", "ref", false, false},
	{"estab/ddd1", "string", false, false},
	{"estab/telefone1", "string", false, false},
	{"estab/ddd2", "string", false, false},
	{"estab/telefone2", "string", false, false},
	{"estab/email", "string", false, false},
	{"socio/empresa", "ref", false, false},
	{"socio/pessoa", "ref", false, false},
	{"socio/tipo_pessoa", "string", false, false},
	{"socio/nome", "string", false, false},
	{"socio/cpf_cnpj", "string", false, false},
	{"socio/chave", "string", false, true},
	{"socio/chave_rel", "string", false, true},
	{"socio/qualificacao", "ref", false, false},
	{"socio/data_entrada", "string", false, false},
	{"socio/pais", "ref", false, false},
	{"socio/faixa_etaria", "string", false, false},
}

func declareSchema(c Txer) error {
	ops := make([]edn.Value, 0, len(schemaAttrs)*4)
	for i, a := range schemaAttrs {
		eid := int64(1000 + i)
		ops = append(ops, addOp(eid, "db/ident", edn.Keyword(a.name)))
		ops = append(ops, addOp(eid, "db/valueType", edn.Keyword("db.type/"+a.vt)))
		card := "db.cardinality/one"
		if a.many {
			card = "db.cardinality/many"
		}
		ops = append(ops, addOp(eid, "db/cardinality", edn.Keyword(card)))
		if a.unique {
			ops = append(ops, addOp(eid, "db/unique", edn.Keyword("db.unique/identity")))
		}
	}
	fmt.Printf("  declaring %d attributes\n", len(schemaAttrs))
	return flush(c, &ops)
}

// ── lookups ──────────────────────────────────────────────────────────────

var lookups = []struct{ zipPrefix, prefix, descAttr string }{
	{"Cnaes", "cnae", "descricao"},
	{"Municipios", "municipio", "nome"},
	{"Naturezas", "natureza", "descricao"},
	{"Qualificacoes", "qualificacao", "descricao"},
	{"Paises", "pais", "nome"},
	{"Motivos", "motivo", "descricao"},
}

func loadLookups(c Txer, dataDir string, batch int) error {
	for _, lk := range lookups {
		zpath, err := findZip(dataDir, lk.zipPrefix)
		if err != nil {
			return err
		}
		r, err := openRows(zpath)
		if err != nil {
			return err
		}
		ops := make([]edn.Value, 0, batch*2)
		total, rowInTx := 0, 0
		for {
			row, err := r.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				r.Close()
				return err
			}
			if len(row) >= 2 && row[0] != "" {
				tid := int64(-(rowInTx + 1))
				ops = append(ops, addOp(tid, lk.prefix+"/codigo", edn.Str(row[0])))
				if row[1] != "" {
					ops = append(ops, addOp(tid, lk.prefix+"/"+lk.descAttr, edn.Str(row[1])))
				}
				total++
				rowInTx++
				if len(ops) >= batch*2 {
					if err := flush(c, &ops); err != nil {
						r.Close()
						return err
					}
					rowInTx = 0
				}
			}
		}
		r.Close()
		if err := flush(c, &ops); err != nil {
			return err
		}
		fmt.Printf("  %s: %s entries\n", lk.prefix, commas(total))
	}
	return nil
}

// ── empresas ─────────────────────────────────────────────────────────────

func loadEmpresas(c Txer, dataDir string, n, batch int) (int, error) {
	zpath, err := findZip(dataDir, "Empresas0")
	if err != nil {
		return 0, err
	}
	r, err := openRows(zpath)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	ops := make([]edn.Value, 0, batch*4)
	refs := newRefTids()
	total := 0
	progress := func() {
		fmt.Printf("    %10s empresas\n", commas(total))
	}
	for total < n {
		row, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return total, err
		}
		if len(row) < 6 {
			continue
		}
		cnpj := nth(row, 0)
		if len(cnpj) != 8 || !allDigits(cnpj) {
			continue
		}
		tid := refs.fresh()
		ops = append(ops, addOp(tid, "empresa/cnpj_base", edn.Str(cnpj)))
		if rs := nth(row, 1); rs != "" {
			ops = append(ops, addOp(tid, "empresa/razao_social", edn.Str(rs)))
		}
		if nat := nth(row, 2); nat != "" {
			ops = append(ops, addOp(tid, "empresa/natureza_juridica", edn.Int(refs.ref(&ops, "natureza/codigo", nat))))
		}
		if qual := nth(row, 3); qual != "" {
			ops = append(ops, addOp(tid, "empresa/qualificacao_resp", edn.Int(refs.ref(&ops, "qualificacao/codigo", qual))))
		}
		if cap := nth(row, 4); cap != "" {
			f, err := strconv.ParseFloat(strings.ReplaceAll(cap, ",", "."), 64)
			if err == nil {
				ops = append(ops, addOp(tid, "empresa/capital_social", edn.Float(f)))
			}
		}
		if porte := nth(row, 5); porte != "" {
			ops = append(ops, addOp(tid, "empresa/porte", edn.Str(porte)))
		}
		total++
		if total%batch == 0 {
			if err := flush(c, &ops); err != nil {
				return total, err
			}
			refs = newRefTids()
			progress()
		}
	}
	if err := flush(c, &ops); err != nil {
		return total, err
	}
	fmt.Printf("  empresas: %s\n", commas(total))
	return total, nil
}

// ── simples (merge via unique upsert) ────────────────────────────────────

func mergeSimples(c Txer, dataDir string, batch, maxRows int) (int, error) {
	zpath, err := findZip(dataDir, "Simples")
	if err != nil {
		return 0, err
	}
	r, err := openRows(zpath)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	ops := make([]edn.Value, 0, batch*2)
	matched, pending, scanned := 0, 0, 0
	for maxRows <= 0 || matched < maxRows {
		row, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return matched, err
		}
		scanned++
		if scanned%1_000_000 == 0 {
			fmt.Printf("    scanned %s, matched %s\n", commas(scanned), commas(matched))
		}
		if len(row) < 7 {
			continue
		}
		var sets [][2]string
		if v := nth(row, 1); v != "" {
			sets = append(sets, [2]string{"empresa/optante_simples", v})
		}
		if v := nth(row, 2); v != "" && v != zeroDate {
			sets = append(sets, [2]string{"empresa/data_opcao_simples", v})
		}
		if v := nth(row, 3); v != "" && v != zeroDate {
			sets = append(sets, [2]string{"empresa/data_exclusao_simples", v})
		}
		if v := nth(row, 4); v != "" {
			sets = append(sets, [2]string{"empresa/optante_mei", v})
		}
		if v := nth(row, 5); v != "" && v != zeroDate {
			sets = append(sets, [2]string{"empresa/data_opcao_mei", v})
		}
		if v := nth(row, 6); v != "" && v != zeroDate {
			sets = append(sets, [2]string{"empresa/data_exclusao_mei", v})
		}
		if len(sets) == 0 {
			continue
		}
		tid := int64(-(pending + 1))
		ops = append(ops, addOp(tid, "empresa/cnpj_base", edn.Str(nth(row, 0))))
		for _, s := range sets {
			ops = append(ops, addOp(tid, s[0], edn.Str(s[1])))
		}
		pending++
		if len(ops) >= batch*2 {
			if err := flush(c, &ops); err != nil {
				return matched, err
			}
			matched += pending
			pending = 0
		}
	}
	if err := flush(c, &ops); err != nil {
		return matched, err
	}
	matched += pending
	fmt.Printf("  simples: %s matched (scanned %s)\n", commas(matched), commas(scanned))
	return matched, nil
}

// ── estabelecimentos ─────────────────────────────────────────────────────

var estabStrAttrs = []struct {
	idx  int
	attr string
}{
	{3, "estab/matriz_filial"}, {4, "estab/nome_fantasia"}, {5, "estab/situacao"},
	{6, "estab/data_situacao"}, {10, "estab/data_inicio_ativ"},
	{13, "estab/tipo_logradouro"}, {14, "estab/logradouro"}, {15, "estab/numero"},
	{16, "estab/complemento"}, {17, "estab/bairro"}, {18, "estab/cep"}, {19, "estab/uf"},
	{21, "estab/ddd1"}, {22, "estab/telefone1"}, {23, "estab/ddd2"}, {24, "estab/telefone2"},
	{27, "estab/email"},
}

var estabRefAttrs = []struct {
	idx   int
	attr  string
	uattr string
}{
	{7, "estab/motivo", "motivo/codigo"},
	{9, "estab/pais", "pais/codigo"},
	{11, "estab/cnae_principal", "cnae/codigo"},
	{20, "estab/municipio", "municipio/codigo"},
}

func flushEstabBatch(c Txer, batch [][]string) error {
	ops := make([]edn.Value, 0, len(batch)*8)
	refs := newRefTids()
	for _, row := range batch {
		cnpjFull := nth(row, 0) + zfill(nth(row, 1), 4) + zfill(nth(row, 2), 2)
		estabTid := refs.fresh()
		ops = append(ops, addOp(estabTid, "estab/cnpj_completo", edn.Str(cnpjFull)))
		etid := refs.ref(&ops, "empresa/cnpj_base", nth(row, 0))
		ops = append(ops, addOp(estabTid, "estab/empresa", edn.Int(etid)))
		for _, sa := range estabStrAttrs {
			if v := nth(row, sa.idx); v != "" {
				ops = append(ops, addOp(estabTid, sa.attr, edn.Str(v)))
			}
		}
		for _, ra := range estabRefAttrs {
			if code := nth(row, ra.idx); code != "" {
				ops = append(ops, addOp(estabTid, ra.attr, edn.Int(refs.ref(&ops, ra.uattr, code))))
			}
		}
		if cnaes := nth(row, 12); cnaes != "" {
			for _, code := range strings.Split(cnaes, ",") {
				code = strings.TrimSpace(code)
				if code != "" {
					ops = append(ops, addOp(estabTid, "estab/cnae_secundario", edn.Int(refs.ref(&ops, "cnae/codigo", code))))
				}
			}
		}
	}
	return flush(c, &ops)
}

func loadEstabs(c Txer, dataDir string, maxRows, batch int) (int, error) {
	zpath, err := findZip(dataDir, "Estabelecimentos0")
	if err != nil {
		return 0, err
	}
	r, err := openRows(zpath)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	var buf [][]string
	saved, scanned := 0, 0
	for {
		row, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return saved, err
		}
		scanned++
		if len(row) >= 30 && len(nth(row, 0)) == 8 && allDigits(nth(row, 0)) {
			buf = append(buf, row)
		}
		if len(buf) >= batch {
			if err := flushEstabBatch(c, buf); err != nil {
				return saved, err
			}
			saved += len(buf)
			buf = buf[:0]
			if saved >= maxRows {
				fmt.Printf("  estabs: %s saved (scanned %s)\n", commas(saved), commas(scanned))
				return saved, nil
			}
		}
	}
	if len(buf) > 0 && saved < maxRows {
		if err := flushEstabBatch(c, buf); err != nil {
			return saved, err
		}
		saved += len(buf)
	}
	fmt.Printf("  estabs: %s saved (scanned %s)\n", commas(saved), commas(scanned))
	return saved, nil
}

// ── socios ───────────────────────────────────────────────────────────────

func upperASCII(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 0x20
		}
	}
	return string(b)
}

func collapseWS(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

func socioChave(cpfCnpj, nome string) string {
	visible := strings.ReplaceAll(cpfCnpj, "*", "")
	norm := upperASCII(collapseWS(strings.TrimSpace(nome)))
	sum := sha256.Sum256([]byte(norm))
	tag := base64.RawURLEncoding.EncodeToString(sum[:])
	if len(tag) > 6 {
		tag = tag[:6]
	}
	return visible + "-" + tag
}

func flushSocioBatch(c Txer, batch [][]string) error {
	ops := make([]edn.Value, 0, len(batch)*8)
	refs := newRefTids()
	for _, row := range batch {
		chave := socioChave(nth(row, 3), nth(row, 2))
		var pessoaTid int64
		if len(chave) < 4 {
			pessoaTid = refs.fresh()
		} else {
			pessoaTid = refs.ref(&ops, "socio/chave", chave)
		}
		if v := nth(row, 1); v != "" {
			ops = append(ops, addOp(pessoaTid, "socio/tipo_pessoa", edn.Str(v)))
		}
		if v := nth(row, 2); v != "" {
			ops = append(ops, addOp(pessoaTid, "socio/nome", edn.Str(v)))
		}
		if v := nth(row, 3); v != "" {
			ops = append(ops, addOp(pessoaTid, "socio/cpf_cnpj", edn.Str(v)))
		}
		if v := nth(row, 6); v != "" {
			ops = append(ops, addOp(pessoaTid, "socio/pais", edn.Int(refs.ref(&ops, "pais/codigo", v))))
		}
		if v := nth(row, 10); v != "" {
			ops = append(ops, addOp(pessoaTid, "socio/faixa_etaria", edn.Str(v)))
		}
		etid := refs.ref(&ops, "empresa/cnpj_base", nth(row, 0))
		var relTid int64
		if len(chave) < 4 {
			relTid = refs.fresh()
		} else {
			relTid = refs.ref(&ops, "socio/chave_rel", chave+"-"+nth(row, 0))
		}
		ops = append(ops, addOp(relTid, "socio/empresa", edn.Int(etid)))
		ops = append(ops, addOp(relTid, "socio/pessoa", edn.Int(pessoaTid)))
		if v := nth(row, 4); v != "" {
			ops = append(ops, addOp(relTid, "socio/qualificacao", edn.Int(refs.ref(&ops, "qualificacao/codigo", v))))
		}
		if v := nth(row, 5); v != "" && v != zeroDate {
			ops = append(ops, addOp(relTid, "socio/data_entrada", edn.Str(v)))
		}
	}
	return flush(c, &ops)
}

func loadSocios(c Txer, dataDir string, batch, maxScan int) (int, error) {
	zpath, err := findZip(dataDir, "Socios0")
	if err != nil {
		return 0, err
	}
	r, err := openRows(zpath)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	var buf [][]string
	total, scanned := 0, 0
	for maxScan <= 0 || scanned <= maxScan {
		row, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return total, err
		}
		if len(row) < 11 {
			continue
		}
		cnpjBase := nth(row, 0)
		if len(cnpjBase) != 8 || !allDigits(cnpjBase) {
			continue
		}
		scanned++
		buf = append(buf, row)
		if len(buf) >= batch {
			if err := flushSocioBatch(c, buf); err != nil {
				return total, err
			}
			total += len(buf)
			buf = buf[:0]
		}
	}
	if len(buf) > 0 {
		if err := flushSocioBatch(c, buf); err != nil {
			return total, err
		}
		total += len(buf)
	}
	fmt.Printf("  socios: %s\n", commas(total))
	return total, nil
}

// ── orchestration ────────────────────────────────────────────────────────

// Load runs the full load (schema → lookups → empresas → simples → estabs →
// socios).
func Load(c Txer, o Opts) error {
	if err := declareSchema(c); err != nil {
		return err
	}
	fmt.Printf("== Lookups (data: %s) ==\n", o.DataDir)
	if err := loadLookups(c, o.DataDir, o.Batch); err != nil {
		return err
	}
	fmt.Printf("== Empresas0 (first %s) ==\n", commas(o.N))
	if _, err := loadEmpresas(c, o.DataDir, o.N, o.Batch); err != nil {
		return err
	}
	if !o.SkipSimples {
		fmt.Println("== Simples (merge via tx upsert) ==")
		if _, err := mergeSimples(c, o.DataDir, o.Batch, 0); err != nil {
			return err
		}
	}
	if !o.SkipEstabs {
		fmt.Println("== Estabelecimentos0 ==")
		if _, err := loadEstabs(c, o.DataDir, o.MaxEstabs, o.Batch); err != nil {
			return err
		}
	}
	if !o.SkipSocios {
		fmt.Println("== Socios0 ==")
		if _, err := loadSocios(c, o.DataDir, o.Batch, o.MaxSocios); err != nil {
			return err
		}
	}
	return nil
}

// Demo prints a first-empresa probe (datalog) like the reference loader.
func Demo(c *client.Client) error {
	chunks, err := c.DatalogAll("[:find ?cnpj ?rs :where [?e :empresa/cnpj_base ?cnpj] [?e :empresa/razao_social ?rs]]")
	if err != nil {
		return err
	}
	var first []string
	for _, ch := range chunks {
		if len(ch.Rows) > 0 {
			first = ch.Rows[0]
			break
		}
	}
	if first == nil {
		fmt.Println("  (empty DB)")
		return nil
	}
	rs := first[1]
	if len(rs) > 40 {
		rs = rs[:40]
	}
	fmt.Printf("first empresa: cnpj=%s rs=%q\n", first[0], rs)
	return nil
}

// ── small helpers ────────────────────────────────────────────────────────

func nth(row []string, i int) string {
	if i < len(row) {
		return row[i]
	}
	return ""
}

func zfill(s string, w int) string {
	if len(s) >= w {
		return s
	}
	return strings.Repeat("0", w-len(s)) + s
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func commas(n int) string {
	neg := n < 0
	s := strconv.Itoa(n)
	if neg {
		s = s[1:]
	}
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

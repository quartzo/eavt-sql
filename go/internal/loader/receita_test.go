package loader

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"

	"eavt-go/internal/edn"
)

type fakeTx struct{ batches [][]edn.Value }

func (f *fakeTx) TxData(ops []edn.Value) error {
	cp := make([]edn.Value, len(ops))
	copy(cp, ops)
	f.batches = append(f.batches, cp)
	return nil
}

func (f *fakeTx) allOps() []edn.Value {
	var out []edn.Value
	for _, b := range f.batches {
		out = append(out, b...)
	}
	return out
}

// hasOp reports whether an op [:db/add eid attr value] matches attr and value
// (value compared by string form; ints match by exact value).
func hasOp(ops []edn.Value, attr string, eid int64, val edn.Value) bool {
	for _, op := range ops {
		l, ok := op.(edn.List)
		if !ok || len(l) != 4 {
			continue
		}
		kw, ok := l[0].(edn.Keyword)
		if !ok || kw != "db/add" {
			continue
		}
		if a, ok := l[2].(edn.Keyword); !ok || string(a) != attr {
			continue
		}
		if n, ok := l[1].(edn.Int); !ok || int64(n) != eid {
			continue
		}
		if l[3] == val {
			return true
		}
	}
	return false
}

func writeZip(t *testing.T, dir, name, content string) {
	t.Helper()
	f, err := os.Create(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, err := zw.Create("data.csv")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestLatin1ToUTF8(t *testing.T) {
	if got := latin1ToUTF8("Servi\xe7o"); got != "Serviço" {
		t.Fatalf("latin1 = %q", got)
	}
	if got := latin1ToUTF8("plain"); got != "plain" {
		t.Fatalf("ascii = %q", got)
	}
}

func TestLoadLookupsSynthetic(t *testing.T) {
	dir := t.TempDir()
	writeZip(t, dir, "Cnaes__20260809T1834.zip", "\"1111\";\"Servi\xe7o X\"\n\"2222\";\"Outro\"\n")
	for _, name := range []string{"Municipios", "Naturezas", "Qualificacoes", "Paises", "Motivos"} {
		writeZip(t, dir, name+"__x.zip", "\"9\";\"d\"\n")
	}
	fake := &fakeTx{}
	if err := loadLookups(fake, dir, 10); err != nil {
		t.Fatal(err)
	}
	ops := fake.allOps()
	if !hasOp(ops, "cnae/codigo", -1, edn.Str("1111")) {
		t.Fatalf("missing cnae/codigo 1111: %v", ops)
	}
	if !hasOp(ops, "cnae/descricao", -1, edn.Str("Serviço X")) {
		t.Fatalf("missing latin-1 descricao: %v", ops)
	}
	// Second row gets tempid -2 (per-row counter resets at flush boundaries).
	if !hasOp(ops, "cnae/codigo", -2, edn.Str("2222")) {
		t.Fatalf("missing cnae/codigo 2222: %v", ops)
	}
}

func TestLoadEmpresasSynthetic(t *testing.T) {
	dir := t.TempDir()
	writeZip(t, dir, "Empresas0__x.zip",
		"\"12345678\";\"ACME LTDA\";\"101\";\"102\";\"1000,50\";\"ME\"\n"+
			"\"bad\";\"Skipped\";\"\";\"\";\"\";\"\"\n")
	fake := &fakeTx{}
	n, err := loadEmpresas(fake, dir, 10, 5)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("loaded %d, want 1", n)
	}
	ops := fake.allOps()
	if !hasOp(ops, "empresa/cnpj_base", -1, edn.Str("12345678")) {
		t.Fatalf("missing cnpj_base: %v", ops)
	}
	if !hasOp(ops, "empresa/razao_social", -1, edn.Str("ACME LTDA")) {
		t.Fatalf("missing razao_social: %v", ops)
	}
	if !hasOp(ops, "empresa/capital_social", -1, edn.Float(1000.50)) {
		t.Fatalf("missing capital_social: %v", ops)
	}
}

func TestSocioChaveStable(t *testing.T) {
	a := socioChave("***12345**", "  john   doe ")
	b := socioChave("***12345**", "JOHN DOE")
	if a != b {
		t.Fatalf("normalization unstable: %q vs %q", a, b)
	}
	if len(a) < 4 || a[:5] != "12345" {
		t.Fatalf("visible cpf wrong: %q", a)
	}
	if c := socioChave("***12345**", "jane doe"); c == a {
		t.Fatal("different names must produce different keys")
	}
}

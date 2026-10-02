package edn

import (
	"reflect"
	"testing"
)

func TestReadVectorTx(t *testing.T) {
	got, err := ReadVector(`[[:db/add -1 :person/name "Alice"]]`)
	if err != nil {
		t.Fatal(err)
	}
	want := []Value{
		List{Keyword("db/add"), Int(-1), Keyword("person/name"), Str("Alice")},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestAtomsAndCommas(t *testing.T) {
	got, err := ReadVector(`[ 1 , 2.5 , true , false , nil , _ , ?v ]`)
	if err != nil {
		t.Fatal(err)
	}
	want := []Value{
		Int(1), Float(2.5), Bool(true), Bool(false), Nil{}, Symbol("_"), Symbol("?v"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestStringEscapes(t *testing.T) {
	got, err := ReadVector(`["a\nb"]`)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []Value{Str("a\nb")}) {
		t.Fatalf("got %#v", got)
	}
}

func TestTrailingContent(t *testing.T) {
	if _, err := Read(`[1] extra`); err == nil {
		t.Fatal("Read should reject trailing content")
	}
	got, err := ReadVector(`[1] extra`)
	if err != nil {
		t.Fatalf("ReadVector should ignore trailing content: %v", err)
	}
	if !reflect.DeepEqual(got, []Value{Int(1)}) {
		t.Fatalf("got %#v", got)
	}
}

func TestRejectMapsAndSets(t *testing.T) {
	if _, err := Read(`{:a 1}`); err == nil {
		t.Fatal("maps should be rejected")
	}
	if _, err := Read(`#{1 2}`); err == nil {
		t.Fatal("sets should be rejected")
	}
}

func TestEmptyVector(t *testing.T) {
	got, err := ReadVector(`[ ]`)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("got %#v, want empty", got)
	}
}

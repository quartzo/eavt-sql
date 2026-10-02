package repl

import (
	"strings"
	"testing"
)

func TestBracketDepth(t *testing.T) {
	cases := []struct {
		s    string
		want int
	}{
		{"[1]", 0},
		{"[", 1},
		{"]]", -2},
		{"[[]]", 0},
		{`["a]b"]`, 0},    // bracket inside string ignored
		{`["a\"b]c"]`, 0}, // escaped quote keeps string open
		{"[?e :a ?v] [?e :b ?v]", 0},
	}
	for _, c := range cases {
		if got := BracketDepth(c.s); got != c.want {
			t.Errorf("BracketDepth(%q) = %d, want %d", c.s, got, c.want)
		}
	}
}

func TestIsCompleteStatement(t *testing.T) {
	if !IsCompleteStatement(`[:find ?v :where [?e :a ?v]]`) {
		t.Error("complete query not recognized")
	}
	if IsCompleteStatement(`[:find ?v`) {
		t.Error("incomplete query recognized as complete")
	}
	if IsCompleteStatement(`?v`) {
		t.Error("non-vector recognized as complete")
	}
}

func TestIsTxData(t *testing.T) {
	if !IsTxData(`[[:db/add -1 :person/name "Alice"]]`) {
		t.Error(":db/add not detected")
	}
	if !IsTxData(`[[:db/retract 1 :person/name "Alice"]]`) {
		t.Error(":db/retract not detected")
	}
	if IsTxData(`[:find ?v :where [?e :a ?v]]`) {
		t.Error("query misdetected as tx-data")
	}
}

func TestHelpText(t *testing.T) {
	// Nim's triple-quoted literal drops the newline after `"""`, so the text
	// starts directly with "Dot commands".
	if !strings.HasPrefix(helpText, "Dot commands") {
		t.Error(`helpText should start with "Dot commands"`)
	}
	if !strings.HasSuffix(helpText, "\n") {
		t.Error("helpText should end with a newline")
	}
	if !strings.Contains(helpText, ".kv-scan <cf>") {
		t.Error("helpText missing dot commands")
	}
}

// Package repl implements the Datalog/tx REPL loop, mirroring
// eavt-repl-nim/src/repl.nim: dot commands, multi-line accumulation on
// bracket depth, EDN tx-data via the wire encoding, tab-separated output.
package repl

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/chzyer/readline"

	"eavt-go/internal/client"
	"eavt-go/internal/edn"
)

// Mode selects how the REPL reads input.
type Mode int

const (
	Interactive Mode = iota
	Pipe
	Exec
)

// BracketDepth counts [] nesting, ignoring brackets inside strings.
func BracketDepth(s string) int {
	depth := 0
	inStr := false
	esc := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if esc {
			esc = false
			continue
		}
		if inStr {
			if c == '\\' {
				esc = true
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '[':
			depth++
		case ']':
			depth--
		}
	}
	return depth
}

// IsCompleteStatement reports a statement starting with '[' and balanced.
func IsCompleteStatement(s string) bool {
	return strings.HasPrefix(s, "[") && BracketDepth(s) == 0
}

// IsTxData reports whether the statement carries EDN tx-data ops.
func IsTxData(s string) bool {
	return strings.Contains(s, ":db/add") || strings.Contains(s, ":db/retract")
}

// Run connects and drives the REPL in the requested mode.
func Run(socketPath string, mode Mode, execCmd string) error {
	c, err := client.Dial(socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: cannot connect to %s\n", socketPath)
		return err
	}
	defer c.Close()

	if mode == Interactive && !stdinIsTTY() {
		mode = Pipe
	}

	if mode != Exec {
		printBanner(socketPath)
	}

	switch mode {
	case Exec:
		return runExec(c, execCmd)
	case Interactive:
		return runInteractive(c)
	default:
		return runPipe(c)
	}
}

func stdinIsTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

func printBanner(socketPath string) {
	fmt.Printf("eavt datalog repl: socket=%s\n", socketPath)
	fmt.Println("Queries: [:find ?v :where [?e :attr ?v]];")
	fmt.Println("Type .help for commands, .quit to exit")
	fmt.Println("")
}

func historyFile() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, ".eavt_datalog_history")
}

// ── input abstraction ────────────────────────────────────────────────────

type lineReader interface {
	Read(prompt string) (string, error) // io.EOF at end of input
}

type readlineInput struct{ rl *readline.Instance }

func (in *readlineInput) Read(prompt string) (string, error) {
	in.rl.SetPrompt(prompt)
	line, err := in.rl.Readline()
	if errors.Is(err, readline.ErrInterrupt) {
		return "", io.EOF
	}
	return line, err
}

type pipeInput struct {
	sc  *bufio.Scanner
	out io.Writer
}

func (in *pipeInput) Read(prompt string) (string, error) {
	fmt.Fprint(in.out, prompt)
	if in.sc.Scan() {
		return in.sc.Text(), nil
	}
	if err := in.sc.Err(); err != nil {
		return "", err
	}
	return "", io.EOF
}

func runInteractive(c *client.Client) error {
	rl, err := readline.NewEx(&readline.Config{
		Prompt:      "eavt-dl> ",
		HistoryFile: historyFile(),
	})
	if err != nil {
		return err
	}
	defer rl.Close()
	return loop(c, &readlineInput{rl: rl})
}

func runPipe(c *client.Client) error {
	return loop(c, &pipeInput{sc: bufio.NewScanner(os.Stdin), out: os.Stdout})
}

func runExec(c *client.Client, cmd string) error {
	trimmed := strings.TrimSpace(cmd)
	if trimmed == "" {
		return nil
	}
	if strings.HasPrefix(trimmed, ".") {
		_, err := handleDot(c, trimmed)
		return err
	}
	if IsCompleteStatement(trimmed) {
		return processStatement(c, trimmed)
	}
	fmt.Fprintln(os.Stderr, "Error: incomplete statement")
	return nil
}

func loop(c *client.Client, in lineReader) error {
	accumulated := ""
	for {
		prompt := "eavt-dl> "
		if accumulated != "" {
			prompt = "       -> "
		}
		line, err := in.Read(prompt)
		if err != nil {
			if errors.Is(err, io.EOF) {
				fmt.Println("")
				return nil
			}
			return err
		}
		stripped := strings.TrimSpace(line)

		if accumulated == "" && strings.HasPrefix(stripped, ".") {
			quit, derr := handleDot(c, stripped)
			if derr != nil {
				return derr
			}
			if quit {
				return nil
			}
			continue
		}
		if strings.HasPrefix(stripped, "--") {
			continue
		}

		accumulated += line + " "
		trimmed := strings.TrimSpace(accumulated)
		if trimmed != "" && IsCompleteStatement(trimmed) {
			if err := processStatement(c, trimmed); err != nil {
				return err
			}
			accumulated = ""
		}
	}
}

func processStatement(c *client.Client, stmt string) error {
	if IsTxData(stmt) {
		return executeTx(c, stmt)
	}
	return executeDatalog(c, stmt)
}

func executeDatalog(c *client.Client, query string) error {
	err := c.Datalog(query, func(ch client.Chunk) error {
		for _, row := range ch.Rows {
			fmt.Println(strings.Join(row, "\t"))
		}
		return nil
	})
	return reportError(err)
}

func executeTx(c *client.Client, text string) error {
	ops, err := edn.ReadVector(text)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error: EDN parse: "+err.Error())
		return nil
	}
	out, err := c.Tx(ops)
	if err != nil {
		return reportError(err)
	}
	fmt.Println(out)
	return nil
}

// reportError prints server errors and swallows them; connection errors
// propagate so the REPL stops.
func reportError(err error) error {
	if err == nil {
		return nil
	}
	var se *client.ServerError
	if errors.As(err, &se) {
		fmt.Fprintln(os.Stderr, "Error: "+se.Msg)
		return nil
	}
	return err
}

// ── dot commands ─────────────────────────────────────────────────────────

func handleDot(c *client.Client, line string) (bool, error) {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return false, nil
	}
	cmd := strings.ToLower(parts[0])
	args := parts[1:]
	arg := func(i int, def string) string {
		if i < len(args) {
			return args[i]
		}
		return def
	}
	cfOf := func(i int) (int, bool) {
		if i >= len(args) {
			return 0, false
		}
		n, err := strconv.Atoi(args[i])
		return n, err == nil
	}
	usage := func(u string) {
		fmt.Fprintln(os.Stderr, "Usage: "+u)
	}
	badCF := func() {
		fmt.Fprintln(os.Stderr, "Error: cf must be >= 10 for key-value operations")
	}

	switch cmd {
	case ".quit", ".exit":
		return true, nil
	case ".help":
		fmt.Print(helpText)
		fmt.Println()
		return false, nil
	case ".flush":
		return false, adminCmd(c, "flush")
	case ".flush-sync":
		return false, adminCmd(c, "flush-sync")
	case ".gc":
		return false, adminCmd(c, "gc")
	case ".gc-dry":
		return false, adminCmd(c, "gc-dry")
	case ".status":
		return false, adminCmd(c, "status")
	case ".tree":
		return false, adminCmd(c, "tree")
	case ".memtable":
		return false, adminCmd(c, "memtable")
	case ".dump":
		a := arg(0, "EAVT")
		if n, err := strconv.Atoi(a); err == nil && n >= 10 {
			return false, kvScan(c, n)
		}
		index := strings.ToUpper(a)
		if index == "EAVT" || index == "AEVT" || index == "AVET" || index == "VAET" {
			return false, dumpCmd(c, index)
		}
		fmt.Fprintln(os.Stderr,
			"Error: index must be one of EAVT, AEVT, AVET, VAET or a CF number >= 10")
		return false, nil
	case ".kv-put":
		if len(args) < 3 {
			usage(".kv-put <cf> <key> <value>")
			return false, nil
		}
		cf, ok := cfOf(0)
		if !ok || cf < 10 {
			badCF()
			return false, nil
		}
		return false, kvPut(c, cf, args[1], args[2])
	case ".kv-get":
		if len(args) < 2 {
			usage(".kv-get <cf> <key>")
			return false, nil
		}
		cf, ok := cfOf(0)
		if !ok || cf < 10 {
			badCF()
			return false, nil
		}
		return false, kvGet(c, cf, args[1])
	case ".kv-delete":
		if len(args) < 2 {
			usage(".kv-delete <cf> <key>")
			return false, nil
		}
		cf, ok := cfOf(0)
		if !ok || cf < 10 {
			badCF()
			return false, nil
		}
		return false, kvDelete(c, cf, args[1])
	case ".kv-scan":
		if len(args) < 1 {
			usage(".kv-scan <cf>")
			return false, nil
		}
		cf, ok := cfOf(0)
		if !ok || cf < 10 {
			badCF()
			return false, nil
		}
		return false, kvScan(c, cf)
	}
	fmt.Fprintln(os.Stderr, "Unknown command: "+line)
	return false, nil
}

func adminCmd(c *client.Client, command string) error {
	out, err := c.Admin(command)
	if err != nil {
		return err
	}
	fmt.Println(out)
	return nil
}

func dumpCmd(c *client.Client, index string) error {
	err := c.Dump(index, func(ch client.Chunk) error {
		for _, row := range ch.Rows {
			fmt.Println(strings.Join(row, "\t"))
		}
		return nil
	})
	return reportError(err)
}

func kvScan(c *client.Client, cf int) error {
	err := c.KVScan(cf, func(ch client.Chunk) error {
		for _, row := range ch.Rows {
			fmt.Println(strings.Join(row, "\t"))
		}
		return nil
	})
	return reportError(err)
}

func kvPut(c *client.Client, cf int, key, value string) error {
	out, err := c.KVPut(cf, key, value)
	if err != nil {
		return reportError(err)
	}
	fmt.Println(out)
	return nil
}

func kvGet(c *client.Client, cf int, key string) error {
	out, err := c.KVGet(cf, key)
	if err != nil {
		return reportError(err)
	}
	fmt.Println(out)
	return nil
}

func kvDelete(c *client.Client, cf int, key string) error {
	out, err := c.KVDelete(cf, key)
	if err != nil {
		return reportError(err)
	}
	fmt.Println(out)
	return nil
}

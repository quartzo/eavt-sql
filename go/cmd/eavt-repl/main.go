// Command eavt-repl is the Go port of the EAVT Datalog REPL
// (eavt-repl-nim).  Usage:
//
//	Usage: eavt-sql-cli-go [OPTIONS] [SOCKET_PATH]
//
// Options:
//
//	--help, -h              Show this help
//	-e, --execute "query"   Execute a Datalog query and exit
//	SOCKET_PATH             Unix socket path (default: auto-detect)
//
// Modes:
//
//	Interactive:    eavt-sql-cli-go                   (REPL with history)
//	Execute:        eavt-sql-cli-go -e "[:find ?v :where [_ :dummy/x ?v]]"
//	Pipe:           echo "[:find ?v :where [?e :attr ?v]]" | eavt-sql-cli-go
package main

import (
	"fmt"
	"os"

	"eavt-go/internal/client"
	"eavt-go/internal/repl"
)

const usage = `Usage: eavt-sql-cli-go [OPTIONS] [SOCKET_PATH]

Options:
  --help, -h              Show this help
  -e, --execute "query"   Execute a Datalog query and exit
  SOCKET_PATH             Unix socket path (default: auto-detect)

Modes:
  Interactive:    eavt-sql-cli-go                   (REPL with history)
  Execute:        eavt-sql-cli-go -e "[:find ?v :where [_ :dummy/x ?v]]"   (run and exit)
  Pipe:           echo "[:find ?v :where [?e :attr ?v]]" | eavt-sql-cli-go (read stdin, no prompt)
`

func main() {
	args := os.Args[1:]
	sockPath := ""
	execCmd := ""

	for i := 0; i < len(args); i++ {
		switch arg := args[i]; {
		case arg == "--help" || arg == "-h":
			fmt.Print(usage)
			fmt.Println()
			os.Exit(0)
		case arg == "-e" || arg == "--execute":
			if i+1 >= len(args) {
				fmt.Fprintf(os.Stderr, "Error: %s requires an argument\n", arg)
				os.Exit(1)
			}
			execCmd = args[i+1]
			i++
		case len(arg) > 0 && arg[0] == '-':
			fmt.Fprintf(os.Stderr, "Unknown option: %s\n", arg)
			fmt.Fprint(os.Stderr, usage)
			fmt.Fprintln(os.Stderr)
			os.Exit(1)
		default:
			sockPath = arg
		}
	}

	if sockPath == "" {
		sockPath = client.DefaultSocketPath()
	}

	mode := repl.Interactive
	if execCmd != "" {
		mode = repl.Exec
	}

	if err := repl.Run(sockPath, mode, execCmd); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

// Command eavt-query is the Go query server: it owns the client socket and
// the internal executor socket, executes Datalog locally on a read-only
// replica populated from the transactor's replication stream, and forwards
// writes/exec to the transactor.
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"eavt-go/internal/querysrv"
)

func runtimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "eavt")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt")
}

func dataDir() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "eavt", "db")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt", "db")
}

func internalSocketPath(clientPath string) string {
	dir := filepath.Dir(clientPath)
	name := filepath.Base(clientPath)
	stem := strings.TrimSuffix(name, ".sock")
	return filepath.Join(dir, stem+"-internal.sock")
}

func main() {
	sockPath := filepath.Join(runtimeDir(), "eavt-query.sock")
	downstreamPath := filepath.Join(runtimeDir(), "eavt-transactor.sock")
	internalPath := ""
	dataPath := ""
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket-path":
			if i+1 < len(args) {
				sockPath = args[i+1]
				i++
			}
		case "--downstream-path":
			if i+1 < len(args) {
				downstreamPath = args[i+1]
				i++
			}
		case "--internal-path":
			if i+1 < len(args) {
				internalPath = args[i+1]
				i++
			}
		case "--data-path":
			if i+1 < len(args) {
				dataPath = args[i+1]
				i++
			}
		case "--print-socket-path":
			fmt.Println(sockPath)
			return
		}
	}
	if dataPath == "" {
		dataPath = dataDir()
	}
	if internalPath == "" {
		internalPath = internalSocketPath(sockPath)
	}
	fmt.Printf("EAVT query server (go) starting on %s -> %s  data=%s\n", sockPath, downstreamPath, dataPath)

	gw := querysrv.NewGateway(downstreamPath, dataPath)

	if err := os.MkdirAll(filepath.Dir(sockPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	_ = os.Remove(sockPath)
	clientLn, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	go acceptLoop(clientLn, gw.ServeClient)

	if err := os.MkdirAll(filepath.Dir(internalPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	_ = os.Remove(internalPath)
	internalLn, err := net.Listen("unix", internalPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	fmt.Printf("Internal executor socket on %s\n", internalPath)
	acceptLoop(internalLn, gw.ServeInternal)
}

func acceptLoop(ln net.Listener, handle func(net.Conn)) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(conn)
	}
}

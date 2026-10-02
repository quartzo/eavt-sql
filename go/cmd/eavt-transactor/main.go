// Command eavt-transactor is the Go data server: read-write engine + segmented
// WAL + replication hub.
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"

	"eavt-go/internal/transactor"
)

func runtimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "eavt")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt")
}

func main() {
	sockPath := filepath.Join(runtimeDir(), "eavt-transactor.sock")
	dataPath := transactor.DefaultDataDir()
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket-path":
			if i+1 < len(args) {
				sockPath = args[i+1]
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
	fmt.Printf("EAVT transactor (go) starting on %s  backend=file path=%s\n", sockPath, dataPath)

	e, err := transactor.NewEngine(dataPath, dataPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	defer e.Close()

	if err := os.MkdirAll(filepath.Dir(sockPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	fmt.Println("Listening...")
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go e.Serve(conn)
	}
}

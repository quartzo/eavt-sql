// Command eavt-query-front is the Go two-layer query front: it owns the client
// socket, compiles Datalog EDN locally and drives the back's internal executor
// socket (nim query server).
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"

	"eavt-go/internal/front"
)

func runtimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "eavt")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt")
}

func main() {
	socketPath := ""
	backPath := ""
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket-path":
			if i+1 < len(args) {
				socketPath = args[i+1]
				i++
			}
		case "--back-path":
			if i+1 < len(args) {
				backPath = args[i+1]
				i++
			}
		case "--help", "-h":
			fmt.Println("Usage: eavt-query-front [--socket-path FRONT_SOCK] [--back-path INTERNAL_SOCK]")
			return
		}
	}
	if socketPath == "" {
		socketPath = filepath.Join(runtimeDir(), "eavt-query-go.sock")
	}
	if backPath == "" {
		backPath = filepath.Join(runtimeDir(), "eavt-query-internal.sock")
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}

	_ = os.Remove(socketPath)
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	fmt.Printf("eavt query front (go) on %s -> back %s\n", socketPath, backPath)

	srv := front.New(front.Config{BackPath: backPath})
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go srv.Serve(conn)
	}
}

// Command eavt-query is the Go query server: it owns the client socket and
// the internal executor socket, executes Datalog locally on a read-only
// replica populated from the transactor's replication stream, and forwards
// writes/exec to the transactor.
package main

import (
	"fmt"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"path/filepath"
	"strings"

	"eavt-go/internal/blobstore"
	"eavt-go/internal/querysrv"
	"eavt-go/internal/replica"
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
	backend := os.Getenv("EAVT_BACKEND")
	var s3 blobstore.S3Config
	pathStyleSet := false
	args := os.Args[1:]
	val := func(i int) string {
		if i+1 < len(args) {
			return args[i+1]
		}
		return ""
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket-path":
			sockPath = val(i)
			i++
		case "--downstream-path":
			downstreamPath = val(i)
			i++
		case "--internal-path":
			internalPath = val(i)
			i++
		case "--data-path":
			dataPath = val(i)
			i++
		case "--backend":
			backend = strings.ToLower(val(i))
			i++
		case "--s3-endpoint":
			s3.Endpoint = val(i)
			i++
		case "--s3-bucket":
			s3.Bucket = val(i)
			i++
		case "--s3-access-key":
			s3.AccessKey = val(i)
			i++
		case "--s3-secret-key":
			s3.SecretKey = val(i)
			i++
		case "--s3-region":
			s3.Region = val(i)
			i++
		case "--s3-prefix":
			s3.Prefix = val(i)
			i++
		case "--s3-path-style":
			s3.PathStyle = val(i) == "true"
			pathStyleSet = true
			i++
		case "--print-socket-path":
			fmt.Println(sockPath)
			return
		}
	}
	if backend == "" {
		backend = "file"
	}
	if s3.Endpoint == "" {
		s3.Endpoint = os.Getenv("EAVT_S3_ENDPOINT")
	}
	if s3.Bucket == "" {
		s3.Bucket = os.Getenv("EAVT_S3_BUCKET")
	}
	if s3.AccessKey == "" {
		s3.AccessKey = os.Getenv("EAVT_S3_ACCESS_KEY")
	}
	if s3.SecretKey == "" {
		s3.SecretKey = os.Getenv("EAVT_S3_SECRET_KEY")
	}
	if s3.Region == "" {
		s3.Region = os.Getenv("EAVT_S3_REGION")
	}
	if s3.Prefix == "" {
		s3.Prefix = os.Getenv("EAVT_S3_PREFIX")
	}
	if !pathStyleSet {
		if v := os.Getenv("EAVT_S3_PATH_STYLE"); v != "" {
			s3.PathStyle = v == "true"
		} else {
			s3.PathStyle = true
		}
	}
	if dataPath == "" {
		dataPath = dataDir()
	}
	if internalPath == "" {
		internalPath = internalSocketPath(sockPath)
	}
	fmt.Printf("EAVT query server (go) starting on %s -> %s  backend=%s data=%s\n", sockPath, downstreamPath, backend, dataPath)

	gw := querysrv.NewGatewayConfig(downstreamPath, replica.Config{Dir: dataPath, Backend: backend, S3: s3})

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
	// Optional profiling for perf work: EAVT_PPROF_QUERY=host:port
	if pp := os.Getenv("EAVT_PPROF_QUERY"); pp != "" {
		go func() {
			if err := http.ListenAndServe(pp, nil); err != nil {
				fmt.Fprintln(os.Stderr, "pprof:", err)
			}
		}()
	}
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

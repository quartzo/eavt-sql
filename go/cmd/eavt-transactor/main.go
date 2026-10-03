// Command eavt-transactor is the Go data server: read-write engine + segmented
// WAL + replication hub.
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"eavt-go/internal/blobstore"
	"eavt-go/internal/transactor"
)

func runtimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "eavt")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "eavt")
}

// argValue extracts the value following flag, or "".
func argValue(args []string, i int) string {
	if i+1 < len(args) {
		return args[i+1]
	}
	return ""
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	sockPath := filepath.Join(runtimeDir(), "eavt-transactor.sock")
	dataPath := transactor.DefaultDataDir()
	backend := envOr("EAVT_BACKEND", "file")
	var s3 blobstore.S3Config
	pathStyleSet := false

	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket-path":
			sockPath = argValue(args, i)
			i++
		case "--data-path", "--path":
			dataPath = argValue(args, i)
			i++
		case "--backend":
			backend = strings.ToLower(argValue(args, i))
			i++
		case "--s3-endpoint":
			s3.Endpoint = argValue(args, i)
			i++
		case "--s3-bucket":
			s3.Bucket = argValue(args, i)
			i++
		case "--s3-access-key":
			s3.AccessKey = argValue(args, i)
			i++
		case "--s3-secret-key":
			s3.SecretKey = argValue(args, i)
			i++
		case "--s3-region":
			s3.Region = argValue(args, i)
			i++
		case "--s3-prefix":
			s3.Prefix = argValue(args, i)
			i++
		case "--s3-path-style":
			s3.PathStyle = argValue(args, i) == "true"
			pathStyleSet = true
			i++
		case "--print-socket-path":
			fmt.Println(sockPath)
			return
		}
	}

	// Environment fallbacks for the S3 backend.
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
			s3.PathStyle = true // default
		}
	}

	if backend != "file" && backend != "s3" {
		fmt.Fprintf(os.Stderr, "unknown backend: %s (use file|s3)\n", backend)
		os.Exit(1)
	}
	if backend == "s3" && (s3.Endpoint == "" || s3.Bucket == "" || s3.AccessKey == "" || s3.SecretKey == "") {
		fmt.Fprintln(os.Stderr, "s3 backend requires EAVT_S3_{ENDPOINT,BUCKET,ACCESS_KEY,SECRET_KEY}")
		os.Exit(1)
	}

	fmt.Printf("EAVT transactor (go) starting on %s  backend=%s path=%s\n", sockPath, backend, dataPath)

	e, err := transactor.NewEngineConfig(transactor.EngineConfig{
		DBPath: dataPath, BlobDir: dataPath, Backend: backend, S3: s3,
	})
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

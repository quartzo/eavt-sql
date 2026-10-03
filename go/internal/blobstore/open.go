// open.go — backend factory (file | s3).
package blobstore

import "fmt"

// Config selects and configures a blob backend.
type Config struct {
	Backend  string // "file" (default) | "s3"
	Path     string // file backend / local dir
	ReadOnly bool
	S3       S3Config
}

// Open constructs the configured backend.
func Open(cfg Config) (BlobStore, error) {
	switch cfg.Backend {
	case "", "file":
		return New(cfg.Path, cfg.ReadOnly)
	case "s3":
		return NewS3(cfg.S3, cfg.ReadOnly)
	default:
		return nil, fmt.Errorf("blobstore: unknown backend %q (use file|s3)", cfg.Backend)
	}
}

package blobstore

import "testing"

func TestOpenSelectsBackend(t *testing.T) {
	fb, err := Open(Config{Backend: "file", Path: t.TempDir(), ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := fb.(*FileBlobStore); !ok {
		t.Fatalf("file backend = %T", fb)
	}

	sb, err := Open(Config{Backend: "s3", S3: S3Config{
		Endpoint: "http://localhost:9000", Bucket: "b", AccessKey: "a", SecretKey: "s",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := sb.(*S3BlobStore); !ok {
		t.Fatalf("s3 backend = %T", sb)
	}

	if _, err := Open(Config{Backend: "bogus", Path: t.TempDir()}); err == nil {
		t.Fatal("unknown backend must error")
	}
}

package blobstore

import (
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

func TestSHA256Vectors(t *testing.T) {
	if got := sha256Hex(nil); got != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Fatalf("sha256(empty) = %s", got)
	}
}

func TestHMACSHA256Vector(t *testing.T) {
	got := hex.EncodeToString(hmacSHA256([]byte("key"), []byte("The quick brown fox jumps over the lazy dog")))
	want := "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
	if got != want {
		t.Fatalf("hmac = %s, want %s", got, want)
	}
}

// AWS "Deriving the Signing Key" documented example.
func TestDeriveSigningKeyVector(t *testing.T) {
	got := hex.EncodeToString(deriveSigningKey(
		"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam"))
	want := "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
	if got != want {
		t.Fatalf("signing key = %s, want %s", got, want)
	}
}

func TestSignV4Structure(t *testing.T) {
	old := nowUTC
	nowUTC = func() time.Time { return time.Date(2015, 8, 30, 12, 36, 0, 0, time.UTC) }
	defer func() { nowUTC = old }()

	s := signV4("AKIDEXAMPLE", "secret", "us-east-1", "s3",
		"https://s3.amazonaws.com", "mybucket", "PUT", "blobs/aa/bb/deadbeef", "", nil, []byte("hello"))
	if s.amzDate != "20150830T123600Z" {
		t.Fatalf("amzDate = %s", s.amzDate)
	}
	if s.contentSha256 != sha256Hex([]byte("hello")) {
		t.Fatalf("contentSha256 = %s", s.contentSha256)
	}
	if !strings.HasPrefix(s.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, ") {
		t.Fatalf("authorization prefix = %s", s.authorization)
	}
	for _, h := range []string{"host", "x-amz-content-sha256", "x-amz-date"} {
		if !strings.Contains(s.authorization, h) {
			t.Fatalf("signed headers missing %s: %s", h, s.authorization)
		}
	}
	// Deterministic for a pinned clock.
	s2 := signV4("AKIDEXAMPLE", "secret", "us-east-1", "s3",
		"https://s3.amazonaws.com", "mybucket", "PUT", "blobs/aa/bb/deadbeef", "", nil, []byte("hello"))
	if s2.authorization != s.authorization {
		t.Fatal("signature not deterministic")
	}
}

// s3.go — S3-backed BlobStore using AWS Signature V4.  Port of
// nim_blobstore/s3/s3_backend.nim.
package blobstore

import (
	"bytes"
	"crypto/rand"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// S3Config configures the S3 backend (nim cfg keys in parentheses).
type S3Config struct {
	Endpoint  string // endpoint
	Bucket    string // bucket_name
	Region    string // region (default us-east-1)
	AccessKey string // access_key
	SecretKey string // secret_key
	Prefix    string // prefix (default "")
	PathStyle bool   // path_style (default true)
}

// S3BlobStore is an S3-backed BlobStore.
type S3BlobStore struct {
	endpoint  string
	bucket    string
	region    string
	accessKey string
	secretKey string
	prefix    string
	pathStyle bool
	readOnly  bool
	client    *http.Client
}

// NewS3 creates an S3 backend from cfg.
func NewS3(cfg S3Config, readOnly bool) (*S3BlobStore, error) {
	switch {
	case cfg.Endpoint == "":
		return nil, fmt.Errorf("s3 init: missing endpoint")
	case cfg.Bucket == "":
		return nil, fmt.Errorf("s3 init: missing bucket_name")
	case cfg.AccessKey == "":
		return nil, fmt.Errorf("s3 init: missing access_key")
	case cfg.SecretKey == "":
		return nil, fmt.Errorf("s3 init: missing secret_key")
	}
	region := cfg.Region
	if region == "" {
		region = "us-east-1"
	}
	return &S3BlobStore{
		endpoint:  cfg.Endpoint,
		bucket:    cfg.Bucket,
		region:    region,
		accessKey: cfg.AccessKey,
		secretKey: cfg.SecretKey,
		prefix:    cfg.Prefix,
		pathStyle: cfg.PathStyle,
		readOnly:  readOnly,
		client:    &http.Client{Timeout: 30 * time.Second},
	}, nil
}

// ── key helpers ──────────────────────────────────────────────────────────

func (b *S3BlobStore) prefixedKey(key string) string {
	if b.prefix == "" {
		return key
	}
	return b.prefix + "/" + key
}

func (b *S3BlobStore) blobKeyForID(id ID) string {
	hex := idToHex(id)
	return b.prefixedKey("blobs/" + hex[0:2] + "/" + hex[2:4] + "/" + hex)
}

func (b *S3BlobStore) rootKeyForName(name string) string {
	return b.prefixedKey("roots/" + name)
}

func lastSegment(s string) string {
	if i := strings.LastIndexByte(s, '/'); i >= 0 {
		return s[i+1:]
	}
	return s
}

func newRandomID() (ID, error) {
	var id ID
	if _, err := rand.Read(id[:]); err != nil {
		return id, fmt.Errorf("urandom: %w", err)
	}
	return id, nil
}

// awsQueryEscape percent-encodes everything but the unreserved set (no `+`).
func awsQueryEscape(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(upperHex[c>>4])
			b.WriteByte(upperHex[c&0x0f])
		}
	}
	return b.String()
}

// ── URL building + HTTP ──────────────────────────────────────────────────

func (b *S3BlobStore) objectURL(objectKey, queryString string) string {
	u, err := url.Parse(b.endpoint)
	scheme := "https"
	host := b.endpoint
	if err == nil && u.Host != "" {
		if u.Scheme != "" {
			scheme = u.Scheme
		}
		host = u.Host
	}
	var sb strings.Builder
	if b.pathStyle {
		sb.WriteString(scheme + "://" + host)
		if objectKey == "" {
			sb.WriteString("/" + b.bucket)
		} else {
			sb.WriteString("/" + b.bucket + "/" + encodePathSegment(objectKey))
		}
	} else {
		sb.WriteString(scheme + "://" + b.bucket + "." + host)
		sb.WriteString("/" + encodePathSegment(objectKey))
	}
	if queryString != "" {
		sb.WriteString("?" + queryString)
	}
	return sb.String()
}

func (b *S3BlobStore) buildHost() string {
	u, err := url.Parse(b.endpoint)
	if err != nil || u.Host == "" {
		return b.endpoint
	}
	return u.Host
}

func (b *S3BlobStore) doRequest(method, objectKey, queryString string, payload []byte) (int, []byte, error) {
	rawURL := b.objectURL(objectKey, queryString)
	host := b.buildHost()
	signed := signV4(b.accessKey, b.secretKey, b.region, "s3", b.endpoint, b.bucket,
		method, objectKey, queryString, nil, payload)

	req, err := http.NewRequest(method, rawURL, bytes.NewReader(payload))
	if err != nil {
		return 0, nil, fmt.Errorf("s3 request: %w", err)
	}
	req.Header.Set("Authorization", signed.authorization)
	req.Header.Set("x-amz-date", signed.amzDate)
	req.Header.Set("x-amz-content-sha256", signed.contentSha256)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Host = host

	resp, err := b.client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("s3 http: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, fmt.Errorf("s3 read body: %w", err)
	}
	return resp.StatusCode, body, nil
}

func (b *S3BlobStore) failReadOnly() error {
	if b.readOnly {
		return fmt.Errorf("read-only")
	}
	return nil
}

// ── ListObjectsV2 ────────────────────────────────────────────────────────

type s3ListResult struct {
	XMLName  xml.Name `xml:"ListBucketResult"`
	Contents []struct {
		Key string `xml:"Key"`
	} `xml:"Contents"`
	IsTruncated           bool   `xml:"IsTruncated"`
	NextContinuationToken string `xml:"NextContinuationToken"`
}

func (b *S3BlobStore) listAll(prefix string) ([]string, error) {
	var all []string
	token := ""
	first := true
	for first || token != "" {
		first = false
		qs := "list-type=2&prefix=" + awsQueryEscape(prefix)
		if token != "" {
			qs += "&continuation-token=" + awsQueryEscape(token)
		}
		code, body, err := b.doRequest("GET", "", qs, nil)
		if err != nil {
			return nil, err
		}
		if code >= 300 {
			return nil, fmt.Errorf("s3 list failed: HTTP %d", code)
		}
		var res s3ListResult
		if len(body) > 0 {
			if err := xml.Unmarshal(body, &res); err != nil {
				return nil, fmt.Errorf("s3 list xml: %w", err)
			}
		}
		for _, c := range res.Contents {
			all = append(all, c.Key)
		}
		if res.IsTruncated && res.NextContinuationToken != "" {
			token = res.NextContinuationToken
		} else {
			token = ""
		}
	}
	return all, nil
}

// ── BlobStore interface ──────────────────────────────────────────────────

// Put stores data under a fresh random id.
func (b *S3BlobStore) Put(data []byte) (ID, error) {
	if err := b.failReadOnly(); err != nil {
		return ID{}, err
	}
	id, err := newRandomID()
	if err != nil {
		return ID{}, err
	}
	return id, b.PutAt(id, data)
}

// PutAt stores data under a caller-chosen id.
func (b *S3BlobStore) PutAt(id ID, data []byte) error {
	if err := b.failReadOnly(); err != nil {
		return err
	}
	code, _, err := b.doRequest("PUT", b.blobKeyForID(id), "", data)
	if err != nil {
		return fmt.Errorf("s3 put: %w", err)
	}
	if code >= 300 {
		return fmt.Errorf("s3 put failed: HTTP %d", code)
	}
	return nil
}

// Get returns the blob, or (nil, false) when absent.
func (b *S3BlobStore) Get(id ID) ([]byte, bool, error) {
	code, body, err := b.doRequest("GET", b.blobKeyForID(id), "", nil)
	if err != nil {
		return nil, false, fmt.Errorf("s3 get: %w", err)
	}
	if code == 404 {
		return nil, false, nil
	}
	if code >= 300 {
		return nil, false, fmt.Errorf("s3 get failed: HTTP %d", code)
	}
	return body, true, nil
}

// Delete removes a blob (best-effort when absent).
func (b *S3BlobStore) Delete(id ID) error {
	if err := b.failReadOnly(); err != nil {
		return err
	}
	code, _, err := b.doRequest("DELETE", b.blobKeyForID(id), "", nil)
	if err != nil {
		return fmt.Errorf("s3 delete: %w", err)
	}
	if code == 404 {
		return nil
	}
	if code >= 300 {
		return fmt.Errorf("s3 delete failed: HTTP %d", code)
	}
	return nil
}

// List returns all blob ids.
func (b *S3BlobStore) List() ([]ID, error) {
	keys, err := b.listAll(b.prefixedKey("blobs/"))
	if err != nil {
		return nil, fmt.Errorf("s3 list: %w", err)
	}
	var out []ID
	for _, k := range keys {
		if id, ok := hexToID(lastSegment(k)); ok {
			out = append(out, id)
		}
	}
	return out, nil
}

// PutRoot writes a named root.
func (b *S3BlobStore) PutRoot(name string, data []byte) error {
	if err := b.failReadOnly(); err != nil {
		return err
	}
	code, _, err := b.doRequest("PUT", b.rootKeyForName(name), "", data)
	if err != nil {
		return fmt.Errorf("s3 putRoot: %w", err)
	}
	if code >= 300 {
		return fmt.Errorf("s3 putRoot failed: HTTP %d", code)
	}
	return nil
}

// GetRoot returns a named root, or (nil, false) when absent.
func (b *S3BlobStore) GetRoot(name string) ([]byte, bool, error) {
	code, body, err := b.doRequest("GET", b.rootKeyForName(name), "", nil)
	if err != nil {
		return nil, false, fmt.Errorf("s3 getRoot: %w", err)
	}
	if code == 404 {
		return nil, false, nil
	}
	if code >= 300 {
		return nil, false, fmt.Errorf("s3 getRoot failed: HTTP %d", code)
	}
	return body, true, nil
}

// ListRoots returns the sorted names of roots ("root_*").
func (b *S3BlobStore) ListRoots() ([]string, error) {
	keys, err := b.listAll(b.prefixedKey("roots/"))
	if err != nil {
		return nil, fmt.Errorf("s3 listRoots: %w", err)
	}
	var names []string
	for _, k := range keys {
		if base := lastSegment(k); strings.HasPrefix(base, "root_") {
			names = append(names, base)
		}
	}
	sort.Strings(names)
	return names, nil
}

// DeleteRoot removes a named root.
func (b *S3BlobStore) DeleteRoot(name string) error {
	if err := b.failReadOnly(); err != nil {
		return err
	}
	code, _, err := b.doRequest("DELETE", b.rootKeyForName(name), "", nil)
	if err != nil {
		return fmt.Errorf("s3 deleteRoot: %w", err)
	}
	if code == 404 {
		return nil
	}
	if code >= 300 {
		return fmt.Errorf("s3 deleteRoot failed: HTTP %d", code)
	}
	return nil
}

// Close is a no-op for the S3 backend (per-request client).
func (b *S3BlobStore) Close() error { return nil }

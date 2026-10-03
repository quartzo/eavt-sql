// sigv4.go — hand-rolled AWS Signature V4 for the S3 backend.  Port of
// nim_blobstore/s3/sigv4.nim (sha256/hmac from the Go stdlib).
package blobstore

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"sort"
	"strings"
	"time"
)

type signedRequest struct {
	authorization string
	amzDate       string
	contentSha256 string
}

// nowUTC is overridable in tests to pin the SigV4 timestamp.
var nowUTC = func() time.Time { return time.Now().UTC() }

func sha256Hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func hmacSHA256(key, msg []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(msg)
	return m.Sum(nil)
}

const upperHex = "0123456789ABCDEF"

// encodePathSegment percent-encodes a path component, preserving the
// unreserved set and `/` (path structure).  Uppercase hex, per AWS.
func encodePathSegment(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~', c == '/':
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(upperHex[c>>4])
			b.WriteByte(upperHex[c&0x0f])
		}
	}
	return b.String()
}

// encodeQueryKey encodes a query key/values, preserving '%' to avoid
// double-encoding already-encoded values (e.g. `%2F` stays `%2F`).
func encodeQueryKey(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '_', c == '.', c == '~', c == '%':
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(upperHex[c>>4])
			b.WriteByte(upperHex[c&0x0f])
		}
	}
	return b.String()
}

func endpointHost(endpoint string) (hostname, signHost string) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Hostname() == "" {
		// Degenerate endpoint: no scheme/host info to extract.
		return "", ""
	}
	hostname = u.Hostname()
	port := u.Port()
	if port != "" && port != "80" && port != "443" {
		return hostname, hostname + ":" + port
	}
	return hostname, hostname
}

func deriveSigningKey(secretKey, dateStamp, region, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secretKey), []byte(dateStamp))
	kRegion := hmacSHA256(kDate, []byte(region))
	kService := hmacSHA256(kRegion, []byte(service))
	return hmacSHA256(kService, []byte("aws4_request"))
}

// signV4 signs an S3 request and returns the headers to attach.  Mirrors
// nim_blobstore/s3/sigv4.nim exactly (including always signing the path-style
// canonical URI, so path_style=false is not covered — same as Nim).
func signV4(accessKey, secretKey, region, service, endpoint, bucket,
	method, objectKey, queryString string, extraHeaders [][2]string, payload []byte) signedRequest {
	payloadHash := sha256Hex(payload)
	now := nowUTC()
	dateStamp := now.Format("20060102")
	amzDate := now.Format("20060102T150405Z")

	_, signHost := endpointHost(endpoint)

	canonicalURI := encodePathSegment("/" + bucket)
	if objectKey != "" {
		canonicalURI = encodePathSegment("/" + bucket + "/" + objectKey)
	}

	// Canonical query string: split, sort by key, re-encode.
	type kv struct{ k, v string }
	var qs []kv
	if queryString != "" {
		for _, part := range strings.Split(queryString, "&") {
			if part == "" {
				continue
			}
			if eq := strings.IndexByte(part, '='); eq < 0 {
				qs = append(qs, kv{part, ""})
			} else {
				qs = append(qs, kv{part[:eq], part[eq+1:]})
			}
		}
	}
	sort.SliceStable(qs, func(i, j int) bool { return qs[i].k < qs[j].k })
	parts := make([]string, len(qs))
	for i, p := range qs {
		parts[i] = encodeQueryKey(p.k) + "=" + encodeQueryKey(p.v)
	}
	canonicalQuery := strings.Join(parts, "&")

	headers := [][2]string{
		{"host", signHost},
		{"x-amz-content-sha256", payloadHash},
		{"x-amz-date", amzDate},
	}
	headers = append(headers, extraHeaders...)

	sortedHeaders := make([][2]string, len(headers))
	copy(sortedHeaders, headers)
	sort.SliceStable(sortedHeaders, func(i, j int) bool {
		return strings.ToLower(sortedHeaders[i][0]) < strings.ToLower(sortedHeaders[j][0])
	})
	var canonicalHeaders strings.Builder
	signedNames := make([]string, 0, len(sortedHeaders))
	for _, h := range sortedHeaders {
		kk := strings.ToLower(strings.TrimSpace(h[0]))
		vv := strings.TrimSpace(h[1])
		canonicalHeaders.WriteString(kk)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(vv)
		canonicalHeaders.WriteByte('\n')
		signedNames = append(signedNames, kk)
	}
	signedHeaders := strings.Join(signedNames, ";")

	canonicalRequest := strings.Join([]string{
		strings.ToUpper(method),
		canonicalURI,
		canonicalQuery,
		canonicalHeaders.String(),
		signedHeaders,
		payloadHash,
	}, "\n")

	credentialScope := dateStamp + "/" + region + "/" + service + "/aws4_request"
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + credentialScope + "\n" +
		sha256Hex([]byte(canonicalRequest))

	signingKey := deriveSigningKey(secretKey, dateStamp, region, service)
	signature := hex.EncodeToString(hmacSHA256(signingKey, []byte(stringToSign)))

	authorization := "AWS4-HMAC-SHA256 " +
		"Credential=" + accessKey + "/" + credentialScope + ", " +
		"SignedHeaders=" + signedHeaders + ", " +
		"Signature=" + signature

	return signedRequest{authorization: authorization, amzDate: amzDate, contentSha256: payloadHash}
}

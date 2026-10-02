package query

// Thin wrappers over the shared EAVT key encoding (avoids the query scanner
// importing the storage packages directly).
import (
	"eavt-go/internal/eavt"
	"eavt-go/internal/sexpr"
)

func encodeEid(n int64) []byte                { return eavt.EncodeEid(n) }
func encodeVariable(s string) []byte          { return eavt.EncodeVariable(s) }
func encodeVariableUnordered(b []byte) []byte { return eavt.EncodeVariableUnordered(b) }
func encodeFixed(v sexpr.Expr) []byte         { return eavt.EncodeFixed(v) }
func encodeBoundValue(v sexpr.Expr) []byte    { return eavt.EncodeBoundValue(v) }
func encodeSuffix(t int64, r bool) uint64     { return eavt.EncodeSuffix(t, r) }
func decodeSuffix(u uint64) (int64, bool)     { return eavt.DecodeSuffix(u) }
func decodeEid(u uint64) int64                { return eavt.DecodeEid(u) }
func decodeInt64(u uint64) int64              { return eavt.DecodeInt64(u) }
func decodeFloat64(u uint64) float64          { return eavt.DecodeFloat64(u) }
func decodeVariableStr(b []byte, start int) string {
	return eavt.DecodeVariableStr(b, start)
}
func beUint32(b []byte, start int) uint32 { return eavt.BeUint32(b, start) }
func beUint64(b []byte, start int) uint64 { return eavt.BeUint64(b, start) }

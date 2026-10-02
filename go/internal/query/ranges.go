package query

// Range constants and the byte range spec used by leapfrog convergence.
const (
	RangeLoOpen int32 = 1
	RangeHiOpen int32 = 2

	RangeOpEq  int32 = 0
	RangeOpNeq int32 = 1
	RangeOpGt  int32 = 2
	RangeOpGte int32 = 3
	RangeOpLt  int32 = 4
	RangeOpLte int32 = 5
	RangeOpIn  int32 = 6
)

// ByteRangeSpec is one interval over encoded value bytes.
type ByteRangeSpec struct {
	Lo    []byte
	Hi    []byte
	HasLo bool
	HasHi bool
	Flags int32
}

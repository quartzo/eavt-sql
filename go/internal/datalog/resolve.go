// resolve.go — attribute resolution + plan stats, mirroring
// nim_datalog/resolve.nim.
package datalog

import (
	"math"
	"strconv"
	"strings"
)

// ResolveFailed indicates an attribute could not be resolved.
type ResolveFailed struct{}

func (ResolveFailed) Error() string { return "attribute resolution failed" }

// ResolveIR resolves BvAttr constants in the a slot (and range bounds)
// against the attr-id table.  id==0 (absent) fails the compile.
func ResolveIR(ir *IR, s *CompileStats) error {
	for i := range ir.Patterns {
		p := ir.Patterns[i]
		if c, ok := p.A.(DsConst); ok {
			if name, ok := c.V.(BvAttr); ok {
				id, ok := s.AttrID(string(name))
				if !ok || id == 0 {
					return ResolveFailed{}
				}
				p.A = DsConst{V: BvResolvedAttr{
					ID: id, Name: string(name),
					IsRef: s.IsRef(string(name)), IsIndexed: s.IsIndexed(string(name)),
				}}
				ir.Patterns[i] = p
			}
		}
	}
	for i := range ir.RangeBounds {
		rb := &ir.RangeBounds[i]
		for bi := range rb.Branches {
			for ci := range rb.Branches[bi] {
				cond := &rb.Branches[bi][ci]
				if name, ok := cond.V.(BvAttr); ok {
					if id, ok := s.AttrID(string(name)); ok {
						cond.V = BvResolvedAttr{
							ID: id, Name: string(name),
							IsRef: s.IsRef(string(name)), IsIndexed: s.IsIndexed(string(name)),
						}
					}
				}
			}
		}
	}
	return nil
}

type estKey struct {
	PatIdx int
	Index  string
	Var    string
}

type planStats struct {
	TotalEAVT float64
	Estimates map[estKey]float64
}

func maxf(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func computePlanStats(ir *IR, s *CompileStats) *planStats {
	total := 1.0
	if v, ok := s.IndexEstimates["EAVT:"]; ok {
		total = v
	}
	total = maxf(total, 1.0)

	estimates := map[estKey]float64{}
	for patIdx, p := range ir.Patterns {
		for _, idx := range IndexOrders {
			for _, pos := range idx.Order {
				vn, ok := p.SlotAt(pos).(DsVar)
				if !ok {
					continue
				}
				posInIdx := indexOf(idx.Order, pos)
				var key strings.Builder
				key.WriteString(idx.Name)
				key.WriteByte(':')
				for bi := 0; bi < posInIdx; bi++ {
					bv := 0
					switch c := p.SlotAt(idx.Order[bi]).(type) {
					case DsConst:
						switch v := c.V.(type) {
						case BvInt:
							bv = int(v)
						case BvResolvedAttr:
							bv = int(v.ID)
						}
					}
					if bv != 0 {
						key.WriteString(strconv.Itoa(bv))
						key.WriteByte(':')
					}
				}
				est, found := s.IndexEstimates[key.String()]
				if found {
					est = maxf(est, 1.0)
				} else {
					est = total
				}
				estimates[estKey{patIdx, idx.Name, string(vn)}] = est
			}
		}
	}
	return &planStats{TotalEAVT: total, Estimates: estimates}
}

func indexOf(order []string, pos string) int {
	for i, s := range order {
		if s == pos {
			return i
		}
	}
	return -1
}

func (ps *planStats) estimate(patIdx int, index, vn string) float64 {
	if f, ok := ps.Estimates[estKey{patIdx, index, vn}]; ok {
		return f
	}
	return math.Inf(1)
}

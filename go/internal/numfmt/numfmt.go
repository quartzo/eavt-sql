// Package numfmt formats floats exactly like Nim's `$float` (dragonbox +
// formatDigits).  Used by the REPL renderer and the EXPLAIN renderer.
package numfmt

import (
	"math"
	"strconv"
	"strings"
)

// FloatString reproduces Nim's $float.
func FloatString(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case f == 0:
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}

	sci := strconv.FormatFloat(f, 'e', -1, 64)
	neg := false
	if sci[0] == '-' {
		neg = true
		sci = sci[1:]
	}
	ei := strings.IndexByte(sci, 'e')
	mantissa := sci[:ei]
	exp, _ := strconv.Atoi(sci[ei+1:])
	digits := strings.Replace(mantissa, ".", "", 1)
	decimalExponent := exp - (len(digits) - 1)

	numDigits := len(digits)
	decimalPoint := numDigits + decimalExponent

	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	if decimalPoint >= -6 && decimalPoint <= 17 {
		switch {
		case decimalPoint <= 0:
			b.WriteString("0.")
			b.WriteString(strings.Repeat("0", -decimalPoint))
			b.WriteString(digits)
		case decimalPoint < numDigits:
			b.WriteString(digits[:decimalPoint])
			b.WriteByte('.')
			b.WriteString(digits[decimalPoint:])
		default:
			b.WriteString(digits)
			b.WriteString(strings.Repeat("0", decimalPoint-numDigits))
			b.WriteString(".0")
		}
		return b.String()
	}
	b.WriteString(digits[:1])
	if numDigits > 1 {
		b.WriteByte('.')
		b.WriteString(digits[1:])
	}
	scientificExponent := decimalPoint - 1
	b.WriteByte('e')
	if scientificExponent < 0 {
		b.WriteByte('-')
		scientificExponent = -scientificExponent
	} else {
		b.WriteByte('+')
	}
	switch {
	case scientificExponent < 10:
		b.WriteByte(byte('0' + scientificExponent))
	case scientificExponent < 100:
		b.WriteByte(byte('0' + scientificExponent/10))
		b.WriteByte(byte('0' + scientificExponent%10))
	default:
		b.WriteByte(byte('0' + scientificExponent/100))
		rem := scientificExponent % 100
		b.WriteByte(byte('0' + rem/10))
		b.WriteByte(byte('0' + rem%10))
	}
	return b.String()
}

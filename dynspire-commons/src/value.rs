use std::cmp::Ordering;

pub use crate::transactor::Value;

pub const TAG_STR: i8 = 2;
pub const TAG_BYTES: i8 = 3;
pub const TAG_BOOL: i8 = 4;
pub const TAG_UINT8: i8 = 5;
pub const TAG_INT8: i8 = 6;
pub const TAG_UINT16: i8 = 7;
pub const TAG_INT16: i8 = 8;
pub const TAG_UINT32: i8 = 9;
pub const TAG_INT32: i8 = 10;
pub const TAG_UINT64: i8 = 11;
pub const TAG_INT64: i8 = 12;
pub const TAG_FLOAT32: i8 = 13;
pub const TAG_FLOAT64: i8 = 14;
pub const TAG_DATE: i8 = 15;
pub const TAG_DATETIME: i8 = 16;
pub const TAG_DURATION: i8 = 17;

pub fn parse_instant_to_us(s: &str) -> Result<i64, ()> {
    let cleaned = s.trim_end_matches('Z').replace("+00:00", "");
    let secs = if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(&cleaned, "%Y-%m-%dT%H:%M:%S%.f") {
        chrono::DateTime::from_timestamp(dt.and_utc().timestamp(), 0)
            .ok_or(())?
            .timestamp()
    } else if let Ok(d) = chrono::NaiveDate::parse_from_str(&cleaned, "%Y-%m-%d") {
        d.and_hms_opt(0, 0, 0).ok_or(())?
            .and_utc()
            .timestamp()
    } else {
        return Err(());
    };
    let frac_us: i64 = if let Some(pos) = cleaned.find('.') {
        let after_dot = &cleaned[pos + 1..];
        let digits: String = after_dot.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.is_empty() {
            0
        } else {
            let padded = format!("{:0<6}", &digits);
            padded.parse().unwrap_or(0i64)
        }
    } else {
        0
    };
    Ok(secs * 1_000_000 + frac_us)
}

impl Value {
    pub fn tag(&self) -> i8 {
        match self {
            Value::Text(_) => TAG_STR,
            Value::Bytes(_) => TAG_BYTES,
            Value::Bool(_) => TAG_BOOL,
            Value::Int64(_) => TAG_INT64,
            Value::Float64(_) => TAG_FLOAT64,
            Value::Timestamp(_) => -1,
            Value::Unknown(t, _) => *t,
        }
    }

    pub fn is_variable(&self) -> bool {
        matches!(self, Value::Text(_) | Value::Bytes(_))
    }

    pub fn is_timestamp(&self) -> bool {
        matches!(self, Value::Timestamp(_))
    }

    pub fn resolve(&self, _lookup: impl Fn(u64) -> String) -> ResolvedValue<'_> {
        match self {
            Value::Text(s) => ResolvedValue::Str(s.as_str()),
            Value::Bytes(b) => ResolvedValue::Bytes(b.as_slice()),
            Value::Bool(b) => ResolvedValue::U64(*b as u64),
            Value::Int64(n) => ResolvedValue::I64(*n),
            Value::Float64(f) => ResolvedValue::F64(*f),
            Value::Timestamp(n) => ResolvedValue::I64(*n),
            Value::Unknown(_, bits) => ResolvedValue::U64(*bits),
        }
    }

    pub fn raw_int(&self) -> i64 {
        match self {
            Value::Bool(b) => *b as i64,
            Value::Int64(n) => *n,
            Value::Timestamp(n) => *n,
            Value::Float64(f) => *f as i64,
            Value::Unknown(_, bits) => *bits as i64,
            Value::Text(_) | Value::Bytes(_) => panic!("raw_int on non-integer Value"),
        }
    }

    pub fn raw_str(&self) -> &str {
        match self {
            Value::Text(s) => s,
            _ => panic!("raw_str on non-text Value"),
        }
    }

    pub fn raw_float(&self) -> f64 {
        match self {
            Value::Float64(f) => *f,
            Value::Int64(n) => *n as f64,
            _ => panic!("raw_float on non-float Value"),
        }
    }

    pub fn text(s: impl Into<String>) -> Value {
        Value::Text(s.into())
    }

    pub fn int64(n: i64) -> Value {
        Value::Int64(n)
    }

    pub fn float64(f: f64) -> Value {
        Value::Float64(f)
    }

    pub fn bool_(b: bool) -> Value {
        Value::Bool(if b { 1 } else { 0 })
    }

    pub fn entity_id(n: u64) -> Value {
        Value::Int64(n as i64)
    }

    pub fn bytes_(b: Vec<u8>) -> Value {
        Value::Bytes(b)
    }

    pub fn timestamp(us: i64) -> Value {
        Value::Timestamp(us)
    }
}

pub enum ResolvedValue<'a> {
    U64(u64),
    I64(i64),
    F64(f64),
    Str(&'a str),
    Owned(String),
    Bytes(&'a [u8]),
}

impl Eq for Value {}

impl PartialOrd for Value {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Value {
    fn cmp(&self, other: &Self) -> Ordering {
        let ta = self.tag();
        let tb = other.tag();
        if ta != tb {
            return ta.cmp(&tb);
        }
        match (self, other) {
            (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
            (Value::Int64(a), Value::Int64(b)) => a.cmp(b),
            (Value::Float64(a), Value::Float64(b)) => a.partial_cmp(b).unwrap_or(Ordering::Equal),
            (Value::Timestamp(a), Value::Timestamp(b)) => a.cmp(b),
            (Value::Text(a), Value::Text(b)) => a.cmp(b),
            (Value::Bytes(a), Value::Bytes(b)) => a.cmp(b),
            (Value::Unknown(_, a), Value::Unknown(_, b)) => a.cmp(b),
            _ => Ordering::Equal,
        }
    }
}

impl std::hash::Hash for Value {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.tag().hash(state);
        match self {
            Value::Text(s) => s.hash(state),
            Value::Bytes(b) => b.hash(state),
            Value::Bool(b) => b.hash(state),
            Value::Int64(n) => n.hash(state),
            Value::Float64(f) => f.to_bits().hash(state),
            Value::Timestamp(n) => n.hash(state),
            Value::Unknown(_, bits) => bits.hash(state),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_value_ordering_cross_tag() {
        let v2 = Value::Text("hello".into());
        let v4 = Value::Bool(1);
        let v12 = Value::Int64(100);
        let v14 = Value::Float64(100.0);

        assert!(v2 < v4);
        assert!(v4 < v12);
        assert!(v12 < v14);
    }

    #[test]
    fn test_value_ordering_same_tag() {
        assert!(Value::Int64(1) < Value::Int64(2));
        assert!(Value::Int64(-1) < Value::Int64(1));
        assert!(Value::Text("a".into()) < Value::Text("b".into()));
        assert!(Value::Float64(-1.0) < Value::Float64(1.0));
    }

    #[test]
    fn test_value_eq() {
        assert_eq!(Value::Int64(42), Value::Int64(42));
        assert_ne!(Value::Int64(42), Value::Int64(43));
        assert_eq!(Value::Text("hello".into()), Value::Text("hello".into()));
        assert_eq!(Value::Float64(3.14), Value::Float64(3.14));
    }

    #[test]
    fn test_value_hash() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        set.insert(Value::Int64(42));
        set.insert(Value::Int64(42));
        set.insert(Value::Text("hello".into()));
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn test_tag() {
        assert_eq!(Value::Text("".into()).tag(), 2);
        assert_eq!(Value::Bytes(vec![]).tag(), 3);
        assert_eq!(Value::Bool(0).tag(), 4);
        assert_eq!(Value::Int64(0).tag(), 12);
        assert_eq!(Value::Float64(0.0).tag(), 14);
        assert_eq!(Value::Timestamp(0).tag(), -1);
    }

    #[test]
    fn test_is_variable() {
        assert!(Value::Text("hello".into()).is_variable());
        assert!(Value::Bytes(vec![]).is_variable());
        assert!(!Value::Int64(42).is_variable());
    }

    #[test]
    fn test_raw_int() {
        assert_eq!(Value::Int64(42).raw_int(), 42);
        assert_eq!(Value::Int64(-1).raw_int(), -1);
        assert_eq!(Value::Bool(1).raw_int(), 1);
    }

    #[test]
    fn test_raw_str() {
        assert_eq!(Value::Text("hello".into()).raw_str(), "hello");
    }

    #[test]
    fn test_raw_float() {
        let v = Value::float64(3.14);
        let f = v.raw_float();
        assert!((f - 3.14).abs() < f64::EPSILON);
    }

    #[test]
    fn test_value_factory_methods() {
        assert_eq!(Value::text("hi"), Value::Text("hi".into()));
        assert_eq!(Value::int64(42), Value::Int64(42));
        assert_eq!(Value::float64(3.0), Value::Float64(3.0));
        assert_eq!(Value::bool_(true), Value::Bool(1));
        assert_eq!(Value::entity_id(100), Value::Int64(100));
        assert_eq!(Value::bytes_(vec![1, 2, 3]), Value::Bytes(vec![1, 2, 3]));
        assert_eq!(Value::timestamp(12345), Value::Timestamp(12345));
    }

}

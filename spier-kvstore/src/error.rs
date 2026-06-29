use std::fmt;

#[derive(Debug)]
pub enum TransactorError {
    Io(std::io::Error),
    Format(String),
    Closed,
    InvalidArg(String),
    ReadOnly,
    Busy,
    Internal(String),
}

impl fmt::Display for TransactorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TransactorError::Io(e) => write!(f, "I/O error: {}", e),
            TransactorError::Format(msg) => write!(f, "format error: {}", msg),
            TransactorError::Closed => write!(f, "store closed"),
            TransactorError::InvalidArg(msg) => write!(f, "invalid argument: {}", msg),
            TransactorError::ReadOnly => write!(f, "store is read-only"),
            TransactorError::Busy => write!(f, "store is busy"),
            TransactorError::Internal(msg) => write!(f, "internal error: {}", msg),
        }
    }
}

impl std::error::Error for TransactorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            TransactorError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for TransactorError {
    fn from(e: std::io::Error) -> Self {
        TransactorError::Io(e)
    }
}

impl From<String> for TransactorError {
    fn from(e: String) -> Self {
        TransactorError::Format(e)
    }
}

pub type TransactorResult<T> = Result<T, TransactorError>;

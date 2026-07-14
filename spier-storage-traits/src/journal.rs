pub trait JournalEngine: Send + Sync {
    fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn journal_read(&self) -> Result<Vec<u8>, String>;
    fn journal_truncate(&self) -> Result<(), String>;
}

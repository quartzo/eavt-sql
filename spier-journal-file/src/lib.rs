use std::collections::HashMap;

use spier_blobstore_nim::NimJournalStore;
use spier_storage_traits::journal::JournalEngine;

/// File-backed journal. Thin adapter over the Nim journal backend
/// (`spier_blobstore_nim::NimJournalStore`), reached through the same C-ABI
/// vtable the blobstore backends use. The on-disk file lives at
/// `<path>/journal/journal`.
pub struct JournalFile {
    inner: NimJournalStore,
}

impl JournalFile {
    pub fn new(config: &HashMap<String, String>) -> Result<Self, String> {
        let inner = NimJournalStore::open(config)?;
        Ok(Self { inner })
    }
}

impl JournalEngine for JournalFile {
    fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.inner.journal_append(key, value)
    }

    fn journal_read(&self) -> Result<Vec<u8>, String> {
        self.inner.journal_read()
    }

    fn journal_truncate(&self) -> Result<(), String> {
        self.inner.journal_truncate()
    }

    fn journal_size(&self) -> Result<u64, String> {
        self.inner.journal_size()
    }
}

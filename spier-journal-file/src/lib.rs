use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

include!(concat!(env!("OUT_DIR"), "/journal_spier.rs"));

struct JournalState {
    base: Mutex<Option<PathBuf>>,
}

fn init(config: &HashMap<String, String>) -> Result<JournalState, String> {
    let base = config.get("path").map(|p| PathBuf::from(format!("{p}/journal")));
    if let Some(ref path) = base {
        fs::create_dir_all(path).map_err(|e| e.to_string())?;
    }
    Ok(JournalState {
        base: Mutex::new(base),
    })
}

impl JournalState {
    fn base(&self) -> Result<PathBuf, String> {
        self.base.lock().unwrap().clone().ok_or_else(|| "no base path configured".into())
    }
}

impl JournalEngine for JournalState {
    fn journal_append(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        let base = self.base()?;
        let path = base.join("journal");
        let mut buf = Vec::with_capacity(8 + key.len() + value.len());
        buf.extend_from_slice(&(key.len() as u32).to_be_bytes());
        buf.extend_from_slice(key);
        buf.extend_from_slice(&(value.len() as u32).to_be_bytes());
        buf.extend_from_slice(value);
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| e.to_string())?;
        file.write_all(&buf).map_err(|e| e.to_string())
    }

    fn journal_read(&self) -> Result<Vec<u8>, String> {
        let base = self.base()?;
        let path = base.join("journal");
        if !path.exists() {
            return Ok(Vec::new());
        }
        let data = fs::read(&path).map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        let mut off = 0usize;
        while off + 8 <= data.len() {
            let klen = u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]) as usize;
            off += 4;
            if off + klen + 4 > data.len() {
                break;
            }
            let jkey = &data[off..off + klen];
            off += klen;
            let vlen = u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]) as usize;
            off += 4;
            if off + vlen > data.len() {
                break;
            }
            let jval = &data[off..off + vlen];
            off += vlen;
            out.extend_from_slice(&(klen as u32).to_be_bytes());
            out.extend_from_slice(jkey);
            out.extend_from_slice(&(vlen as u32).to_be_bytes());
            out.extend_from_slice(jval);
        }
        Ok(out)
    }

    fn journal_truncate(&self) -> Result<(), String> {
        let base = self.base()?;
        let path = base.join("journal");
        if path.exists() {
            fs::remove_file(&path).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

impl_journal_spier!(JournalState, init, "spier_journal_file");

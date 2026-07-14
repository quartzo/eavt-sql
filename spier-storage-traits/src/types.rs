pub struct CfStats {
    pub name: String,
    pub num_keys: u64,
    pub live_size: u64,
    pub sst_size: u64,
    pub num_sst: u64,
    pub memtable_size: u64,
}

impl CfStats {
    pub fn parse(buf: &[u8]) -> Result<Self, String> {
        if buf.len() < 2 {
            return Err("cf_stats: too short".into());
        }
        let name_len = u16::from_le_bytes([buf[0], buf[1]]) as usize;
        if buf.len() < 2 + name_len + 40 {
            return Err("cf_stats: incomplete".into());
        }
        let name = String::from_utf8_lossy(&buf[2..2 + name_len]).to_string();
        let off = 2 + name_len;
        Ok(Self {
            name,
            num_keys: u64::from_le_bytes(buf[off..off + 8].try_into().unwrap()),
            live_size: u64::from_le_bytes(buf[off + 8..off + 16].try_into().unwrap()),
            sst_size: u64::from_le_bytes(buf[off + 16..off + 24].try_into().unwrap()),
            num_sst: u64::from_le_bytes(buf[off + 24..off + 32].try_into().unwrap()),
            memtable_size: u64::from_le_bytes(buf[off + 32..off + 40].try_into().unwrap()),
        })
    }
}

pub struct DbStats {
    pub total_sst_size: u64,
    pub total_live_size: u64,
}

impl DbStats {
    pub fn parse(buf: &[u8]) -> Result<Self, String> {
        if buf.len() < 16 {
            return Err("db_stats: too short".into());
        }
        Ok(Self {
            total_sst_size: u64::from_le_bytes(buf[0..8].try_into().unwrap()),
            total_live_size: u64::from_le_bytes(buf[8..16].try_into().unwrap()),
        })
    }
}

pub struct GcFullResult {
    pub roots_scanned: usize,
    pub roots_removed: usize,
    pub blobs_scanned: usize,
    pub blobs_removed: usize,
    pub live_uuids: usize,
    pub dry_run: bool,
}

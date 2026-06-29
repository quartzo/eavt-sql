mod eavt {
    tonic::include_proto!("eavt");
}

use std::sync::Arc;
use tonic::{Request, Response, Status};

use eavt::eavt_service_server::{EavtService, EavtServiceServer};
use dynspire_commons::query_engine::{DynSpireQuery, QueryEngine};
use dynspire_commons::transactor::query_codec;

pub struct EavtServer {
    client: Arc<DynSpireQuery>,
    writable: bool,
}

impl EavtServer {
    pub fn new(client: DynSpireQuery, writable: bool) -> Self {
        Self { client: Arc::new(client), writable }
    }
}

/// Returns true if the SQL statement mutates data or schema.
fn is_write_sql(sql: &str) -> bool {
    let upper = sql.trim_start().to_uppercase();
    // Skip EXPLAIN/DATALOG prefixes — they only show a plan, no side effects.
    let body = upper
        .strip_prefix("EXPLAIN ")
        .or_else(|| upper.strip_prefix("DATALOG "))
        .unwrap_or(&upper);
    let first = body.split_whitespace().next().unwrap_or("");
    matches!(first, "UPSERT" | "UPDATE" | "DELETE" | "ATTRIBUTE" | "PARTITION")
}

fn value_to_proto(v: &dynspire_commons::value::Value) -> Option<eavt::Value> {
    use dynspire_commons::value::Value::*;
    Some(match v {
        Int64(n) => eavt::Value { kind: Some(eavt::value::Kind::IntVal(*n)) },
        Float64(f) => eavt::Value { kind: Some(eavt::value::Kind::FloatVal(*f)) },
        Text(s) => eavt::Value { kind: Some(eavt::value::Kind::TextVal(s.clone())) },
        Bool(b) => eavt::Value { kind: Some(eavt::value::Kind::BoolVal(*b != 0)) },
        Bytes(b) => eavt::Value { kind: Some(eavt::value::Kind::BytesVal(b.clone())) },
        _ => return None,
    })
}

fn proto_to_value(v: &eavt::Value) -> dynspire_commons::value::Value {
    use eavt::value::Kind;
    match &v.kind {
        Some(Kind::IntVal(n)) => dynspire_commons::value::Value::Int64(*n),
        Some(Kind::FloatVal(f)) => dynspire_commons::value::Value::Float64(*f),
        Some(Kind::TextVal(s)) => dynspire_commons::value::Value::text(s.clone()),
        Some(Kind::BoolVal(b)) => dynspire_commons::value::Value::Bool(*b as u8),
        Some(Kind::BytesVal(b)) => dynspire_commons::value::Value::Bytes(b.clone()),
        Some(Kind::RefVal(id)) => dynspire_commons::value::Value::entity_id(*id),
        None => dynspire_commons::value::Value::Int64(0),
    }
}

const U64_MAX: u64 = u64::MAX;

fn run_sql(
    client: &DynSpireQuery,
    query: &str,
    params: &[dynspire_commons::value::Value],
    limit: Option<u32>,
    as_of_us: Option<u64>,
) -> Result<(usize, Vec<dynspire_commons::value::Value>), String> {
    let params_bytes = query_codec::encode_values(params);
    let prog = client.compile_sql(query, &params_bytes)?;
    let limit_val = limit.map(|l| l as u64).unwrap_or(U64_MAX);
    let as_of_val = as_of_us.unwrap_or(U64_MAX);
    let result_bytes = client.run_vm(prog, &params_bytes, limit_val, as_of_val)?;
    // prog (ProgramHandle) drops here — Arc refcount handles cleanup, no free_program.

    if result_bytes.is_empty() {
        return Ok((0, Vec::new()));
    }
    let num_cols = u32::from_be_bytes([result_bytes[0], result_bytes[1], result_bytes[2], result_bytes[3]]) as usize;
    let values = query_codec::decode_values(&result_bytes[4..])?;
    Ok((num_cols, values))
}

#[tonic::async_trait]
impl EavtService for EavtServer {
    type SqlStream = tokio_stream::wrappers::ReceiverStream<Result<eavt::SqlRow, Status>>;

    async fn sql(
        &self,
        request: Request<eavt::SqlRequest>,
    ) -> Result<Response<Self::SqlStream>, Status> {
        let req = request.into_inner();
        let params: Vec<dynspire_commons::value::Value> = req.params.iter().map(proto_to_value).collect();
        let params_bytes = query_codec::encode_values(&params);

        let prog = self.client.compile_sql(&req.query, &params_bytes)
            .map_err(|e| {
                if e.contains("SELECT * with no conditions") {
                    Status::invalid_argument(e)
                } else {
                    Status::internal(e)
                }
            })?;

        let limit_val = req.limit.map(|v| v as u64).unwrap_or(U64_MAX);
        let as_of_val = req.as_of_us.map(|v| v as u64).unwrap_or(U64_MAX);

        let (tx, rx) = tokio::sync::mpsc::channel(128);
        let client = self.client.clone();

        std::thread::Builder::new()
            .name("vm-cursor".into())
            .spawn(move || {
                let session = match client.run_vm_cursor(prog, &params_bytes, limit_val, as_of_val) {
                    Ok(s) => s,
                    Err(e) => { let _ = tx.blocking_send(Err(Status::internal(e))); return; }
                };

                loop {
                    let batch = match client.session_next_batch(session.clone(), 1024) {
                        Ok(b) => b,
                        Err(e) => { let _ = tx.blocking_send(Err(Status::internal(e))); return; }
                    };
                    if batch.is_empty() { return; }

                    let rows = match query_codec::decode_rows(&batch) {
                        Ok(r) => r,
                        Err(e) => { let _ = tx.blocking_send(Err(Status::internal(e))); return; }
                    };

                    for row in rows {
                        let sql_row = eavt::SqlRow {
                            values: row.iter().filter_map(value_to_proto).collect(),
                        };
                        if tx.blocking_send(Ok(sql_row)).is_err() { return; }
                    }
                }
            })
            .map_err(|e| Status::internal(format!("failed to spawn cursor thread: {e}")))?;

        Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)))
    }

    async fn execute(
        &self,
        request: Request<eavt::SqlRequest>,
    ) -> Result<Response<eavt::ExecuteResponse>, Status> {
        let req = request.into_inner();
        let query = req.query.trim().to_uppercase();

        if query == "FLUSH" {
            if !self.writable {
                return Err(Status::permission_denied("server is read-only (start with --writable to enable writes)"));
            }
            self.client.flush().map_err(|e| Status::internal(e))?;
            return Ok(Response::new(eavt::ExecuteResponse { rows: vec![] }));
        }

        if !self.writable && is_write_sql(&req.query) {
            return Err(Status::permission_denied("server is read-only (start with --writable to enable writes)"));
        }

        if query == "STATUS" {
            let path = self.client.path().map_err(|e| Status::internal(e))?;
            let storage_mode = if path.starts_with("s3://") { "s3" } else if path == ":memory:" { "memory" } else { "file" };
            let row = eavt::SqlRow {
                values: vec![
                    eavt::Value { kind: Some(eavt::value::Kind::TextVal(path)) },
                    eavt::Value { kind: Some(eavt::value::Kind::TextVal(storage_mode.to_string())) },
                ],
            };
            return Ok(Response::new(eavt::ExecuteResponse { rows: vec![row] }));
        }

        let params: Vec<dynspire_commons::value::Value> = req.params.iter().map(proto_to_value).collect();

        let (num_cols, values) = run_sql(
            &self.client, &req.query, &params,
            req.limit.map(|v| v as u32), req.as_of_us.map(|v| v as u64),
        ).map_err(Status::internal)?;

        let rows: Vec<eavt::SqlRow> = if num_cols > 0 {
            values.chunks(num_cols).map(|chunk| {
                eavt::SqlRow {
                    values: chunk.iter().filter_map(value_to_proto).collect(),
                }
            }).collect()
        } else {
            Vec::new()
        };

        Ok(Response::new(eavt::ExecuteResponse { rows }))
    }

    async fn status(
        &self,
        _request: Request<eavt::StatusRequest>,
    ) -> Result<Response<eavt::StatusResponse>, Status> {
        let db_stats_bytes = self.client.db_stats().map_err(|e| Status::internal(e))?;
        let db_stats = dynspire_commons::transactor::types::DbStats::parse(&db_stats_bytes)
            .map_err(|e| Status::internal(e))?;
        let mt_size = self.client.memtable_size().map_err(|e| Status::internal(e))?;
        let wal_size = self.client.journal_size().map_err(|e| Status::internal(e))?;
        let path = self.client.path().map_err(|e| Status::internal(e))?;
        let storage_mode = if path.starts_with("s3://") { "s3" } else if path == ":memory:" { "memory" } else { "file" };
        let blobs_path = std::path::Path::new(&path).with_extension("blobs");
        let disk_usage = dir_size(&blobs_path);

        Ok(Response::new(eavt::StatusResponse {
            db_path: path,
            storage_mode: storage_mode.to_string(),
            disk_usage,
            sst_size: db_stats.total_sst_size,
            live_data: db_stats.total_live_size,
            memtable_size: mt_size,
            wal_size,
        }))
    }

    async fn tree(
        &self,
        _request: Request<eavt::TreeRequest>,
    ) -> Result<Response<eavt::TreeResponse>, Status> {
        let cf_names = ["eavt", "aevt", "avet", "vaet"];
        let mut cfs = Vec::new();
        for (i, name) in cf_names.iter().enumerate() {
            let buf = self.client.cf_stats(i as u32).map_err(|e| Status::internal(e))?;
            let stats = dynspire_commons::transactor::types::CfStats::parse(&buf)
                .map_err(|e| Status::internal(e))?;
            cfs.push(eavt::CfStatsInfo {
                name: name.to_string(),
                num_keys: stats.num_keys,
                live_size: stats.live_size,
                sst_size: stats.sst_size,
                num_sst: stats.num_sst,
                memtable_size: stats.memtable_size,
            });
        }
        Ok(Response::new(eavt::TreeResponse { cfs }))
    }

    type DumpStream = tokio_stream::wrappers::ReceiverStream<Result<eavt::DatomRow, Status>>;

    async fn dump(
        &self,
        request: Request<eavt::DumpRequest>,
    ) -> Result<Response<Self::DumpStream>, Status> {
        let req = request.into_inner();
        let index = req.index.to_uppercase();
        if index != "EAVT" {
            return Err(Status::invalid_argument("only EAVT index supported via spier"));
        }

        let result_bytes = self.client.scan_datoms(U64_MAX).map_err(|e| Status::internal(e))?;

        if result_bytes.is_empty() {
            let (_tx, rx) = tokio::sync::mpsc::channel(128);
            return Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)));
        }

        let _num_cols = u32::from_be_bytes([result_bytes[0], result_bytes[1], result_bytes[2], result_bytes[3]]);
        let values = query_codec::decode_values(&result_bytes[4..])
            .map_err(|e| Status::internal(e))?;

        let rows: Vec<eavt::DatomRow> = values.chunks(5).map(|chunk| {
            let e = match &chunk[0] { dynspire_commons::value::Value::Int64(n) => *n as u64, _ => 0 };
            let attr_name = match &chunk[2] { dynspire_commons::value::Value::Text(s) => s.clone(), _ => String::new() };
            let t = match &chunk[4] { dynspire_commons::value::Value::Int64(n) => *n as u64, _ => 0 };
            eavt::DatomRow {
                e,
                attr: attr_name,
                value: value_to_proto(&chunk[3]),
                t,
            }
        }).collect();

        let (tx, rx) = tokio::sync::mpsc::channel(128);
        tokio::spawn(async move {
            for row in rows {
                if tx.send(Ok(row)).await.is_err() { break; }
            }
        });
        Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)))
    }

    async fn memtable(
        &self,
        _request: Request<eavt::MemtableRequest>,
    ) -> Result<Response<eavt::MemtableResponse>, Status> {
        let mt_size = self.client.memtable_size().map_err(|e| Status::internal(e))?;
        let wal_size = self.client.journal_size().map_err(|e| Status::internal(e))?;
        let cf_names = ["eavt", "aevt", "avet", "vaet"];
        let mut cfs = Vec::new();
        for (i, name) in cf_names.iter().enumerate() {
            let count = self.client.memtable_count(i as u32).map_err(|e| Status::internal(e))?;
            cfs.push(eavt::MemtableCfInfo {
                name: name.to_string(),
                count,
            });
        }
        Ok(Response::new(eavt::MemtableResponse {
            memtable_size: mt_size,
            wal_size,
            cfs,
        }))
    }

    async fn flush(
        &self,
        _request: Request<eavt::FlushRequest>,
    ) -> Result<Response<eavt::FlushResponse>, Status> {
        if !self.writable {
            return Err(Status::permission_denied("server is read-only (start with --writable to enable writes)"));
        }
        let mt_before = self.client.memtable_size().map_err(|e| Status::internal(e))?;
        let wal_before = self.client.journal_size().map_err(|e| Status::internal(e))?;
        self.client.flush().map_err(|e| Status::internal(e))?;
        let mt_after = self.client.memtable_size().map_err(|e| Status::internal(e))?;
        let wal_after = self.client.journal_size().map_err(|e| Status::internal(e))?;
        Ok(Response::new(eavt::FlushResponse {
            memtable_before: mt_before,
            memtable_after: mt_after,
            wal_before,
            wal_after,
        }))
    }
}

fn dir_size(path: &std::path::Path) -> u64 {
    let mut total = 0u64;
    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() {
                    total += meta.len();
                } else if meta.is_dir() {
                    total += dir_size(&entry.path());
                }
            }
        }
    }
    total
}

use clap::{Parser, Subcommand};

fn open_config(db_path: &str) -> std::collections::HashMap<String, String> {
    let mut m = std::collections::HashMap::new();
    if db_path.starts_with("s3://") {
        m.insert("backend".into(), "s3".into());
    } else if db_path == ":memory:" {
        let tmp = format!("/tmp/opencode/eavt-server-{}", std::process::id());
        m.insert("backend".into(), "file".into());
        m.insert("path".into(), format!("{tmp}/db"));
        return m;
    } else {
        m.insert("backend".into(), "file".into());
    }
    m.insert("path".into(), db_path.into());
    m
}

fn open_query(db_path: &str, gc_max_age_secs: Option<u64>) -> Result<DynSpireQuery, String> {
    let mut config = open_config(db_path);
    if let Some(secs) = gc_max_age_secs {
        config.insert("gc_max_age_secs".into(), secs.to_string());
    }
    DynSpireQuery::connect("spier_eavt_query", &config)
}

#[derive(Parser)]
#[command(name = "eavt-server", about = "EAVT gRPC server")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Start the gRPC server.
    Rpc {
        /// Database path (file, s3://bucket/prefix, :memory:)
        db_path: String,
        /// Listen address
        #[arg(short, long, default_value = "0.0.0.0:50051")]
        addr: String,
        /// Enable writes (default: read-only).
        #[arg(long, default_value_t = false)]
        writable: bool,
        /// GC max-age threshold in minutes for the background poller (default: 720 = 12h).
        #[arg(long)]
        gc_max_age_mins: Option<u64>,
    },
    /// Run a single garbage-collection cycle and exit.
    Gc {
        /// Database path (file, s3://bucket/prefix, :memory:)
        db_path: String,
        /// Dry-run — report what would be removed without deleting.
        #[arg(long, default_value_t = false)]
        dry_run: bool,
        /// GC max-age threshold in minutes (default: 720 = 12h).
        #[arg(long)]
        max_age_mins: Option<u64>,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    match Cli::parse().command {
        Command::Rpc { db_path, addr, writable, gc_max_age_mins } => {
            let gc_secs = gc_max_age_mins.map(|m| m * 60);
            let client = open_query(&db_path, gc_secs)?;
            let addr = addr.parse()?;
            println!("eavt-server listening on {} ({})", addr, if writable { "writable" } else { "read-only" });
            tonic::transport::Server::builder()
                .add_service(EavtServiceServer::new(EavtServer::new(client, writable)))
                .serve(addr)
                .await?;
        }
        Command::Gc { db_path, dry_run, max_age_mins } => {
            let gc_secs = max_age_mins.map(|m| m * 60);
            let client = open_query(&db_path, gc_secs)?;
            run_gc_once(&client, dry_run)?;
        }
    }
    Ok(())
}

fn run_gc_once(client: &DynSpireQuery, dry_run: bool) -> Result<(), Box<dyn std::error::Error>> {
    let buf = client.gc_full(dry_run, false).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;
    if buf.len() < 41 {
        eprintln!("gc_full: unexpected response length ({})", buf.len());
        return Ok(());
    }
    let roots_scanned = u64::from_le_bytes(buf[0..8].try_into().unwrap());
    let roots_removed = u64::from_le_bytes(buf[8..16].try_into().unwrap());
    let blobs_scanned = u64::from_le_bytes(buf[16..24].try_into().unwrap());
    let blobs_removed = u64::from_le_bytes(buf[24..32].try_into().unwrap());
    let live_uuids = u64::from_le_bytes(buf[32..40].try_into().unwrap());
    let is_dry = buf[40] != 0;
    println!(
        "GC {} (dry_run={}): roots scanned={} removed={}, blobs scanned={} removed={}, live_uuids={}",
        if is_dry { "preview" } else { "done" },
        is_dry, roots_scanned, roots_removed, blobs_scanned, blobs_removed, live_uuids,
    );
    Ok(())
}

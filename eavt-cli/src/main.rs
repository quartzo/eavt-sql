use clap::Parser;

mod proto {
    tonic::include_proto!("eavt");
}

use proto::eavt_service_client::EavtServiceClient;

#[derive(Parser)]
#[command(name = "eavt-repl", about = "Interactive SQL REPL for EAVT databases (gRPC client)")]
struct Cli {
    /// gRPC server address (e.g. localhost:50051)
    server: String,
}

fn main() {
    let cli = Cli::parse();
    if let Err(e) = run(&cli.server) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn run(addr: &str) -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let client = rt.block_on(async {
        EavtServiceClient::connect(format!("http://{}", addr))
            .await
            .map_err(|e| e.to_string())
    })?;

    println!("eavt-sql repl: server={}", addr);
    println!("Type .help for commands, .quit to exit");
    println!();

    let hist_file = dirs_home().join(".eavt_sql_history");
    let mut rl = rustyline::DefaultEditor::new()
        .map_err(|e| format!("readline error: {}", e))?;
    let _ = rl.load_history(&hist_file);

    let mut client = client;
    let mut accumulated = String::new();
    loop {
        let prompt = if accumulated.is_empty() { "eavt-sql> " } else { "       -> " };
        match rl.readline(prompt) {
            Ok(line) => {
                let stripped = line.trim();

                if accumulated.is_empty() && stripped.starts_with('.') {
                    rl.add_history_entry(&line).ok();
                    if execute_dot_command(&mut client, &rt, stripped) {
                        break;
                    }
                    continue;
                }

                accumulated.push_str(&line);
                accumulated.push(' ');

                while let Some(semi_pos) = accumulated.find(';') {
                    let stmt_str = accumulated[..semi_pos].trim().to_string();
                    accumulated = accumulated[semi_pos + 1..].trim_start().to_string();

                    if stmt_str.is_empty() || stmt_str.starts_with("--") {
                        continue;
                    }

                    rl.add_history_entry(&format!("{};", stmt_str)).ok();
                    execute_sql(&mut client, &rt, &stmt_str);
                }

                let trimmed = accumulated.trim();
                if !trimmed.is_empty() && !trimmed.starts_with("--") {
                    continue;
                }
                accumulated.clear();
            }
            Err(_) => {
                println!();
                break;
            }
        }
    }

    let _ = rl.save_history(&hist_file);
    Ok(())
}

fn execute_dot_command(
    client: &mut EavtServiceClient<tonic::transport::Channel>,
    rt: &tokio::runtime::Runtime,
    line: &str,
) -> bool {
    let parts: Vec<&str> = line.split_whitespace().collect();
    let cmd = parts[0].to_lowercase();
    let args = &parts[1..];

    match cmd.as_str() {
        ".quit" | ".exit" => return true,
        ".help" => {
            println!("Dot commands (no semicolon):");
            println!("  .quit, .exit           Exit the REPL");
            println!("  .help                  Show this help");
            println!("  .flush                 Flush MemTable to disk");
            println!("  .status                Database overview");
            println!("  .tree                  Per-column-family stats");
            println!("  .memtable              MemTable contents and sizes");
            println!("  .dump [EAVT|AEVT|...]  Dump active datoms");
            println!();
            println!("SQL statements must end with ;");
        }
        ".flush" => {
            let req = proto::FlushRequest {};
            match rt.block_on(client.flush(req)) {
                Ok(resp) => {
                    let r = resp.into_inner();
                    println!("Flushed: MemTable {} -> {}, WAL {} -> {}",
                        fmt_size(r.memtable_before), fmt_size(r.memtable_after),
                        fmt_size(r.wal_before), fmt_size(r.wal_after));
                }
                Err(e) => eprintln!("Error: {}", e.message()),
            }
        }
        ".status" => {
            let req = proto::StatusRequest {};
            match rt.block_on(client.status(req)) {
                Ok(resp) => {
                    let r = resp.into_inner();
                    println!("Database:     {}", r.db_path);
                    println!("Storage mode: {}", r.storage_mode);
                    println!("Disk usage:   {}", fmt_size(r.disk_usage));
                    println!("SST size:     {}", fmt_size(r.sst_size));
                    println!("Live data:    {}", fmt_size(r.live_data));
                    println!("MemTable:     {}", fmt_size(r.memtable_size));
                    println!("WAL:          {}", fmt_size(r.wal_size));
                }
                Err(e) => eprintln!("Error: {}", e.message()),
            }
        }
        ".tree" => {
            let req = proto::TreeRequest {};
            match rt.block_on(client.tree(req)) {
                Ok(resp) => {
                    for cf in &resp.into_inner().cfs {
                        println!("=== {} ===", cf.name);
                        println!("  Est. keys:    {}", cf.num_keys);
                        println!("  Live size:    {}", fmt_size(cf.live_size));
                        println!("  SST size:     {}", fmt_size(cf.sst_size));
                        println!("  MemTable:     {}", fmt_size(cf.memtable_size));
                        println!();
                    }
                }
                Err(e) => eprintln!("Error: {}", e.message()),
            }
        }
        ".memtable" => {
            let req = proto::MemtableRequest {};
            match rt.block_on(client.memtable(req)) {
                Ok(resp) => {
                    let r = resp.into_inner();
                    println!("MemTable: {}   WAL: {}", fmt_size(r.memtable_size), fmt_size(r.wal_size));
                    println!();
                    println!("{:<8} {:>10}", "CF", "Count");
                    println!("{}", "-".repeat(20));
                    for cf in &r.cfs {
                        println!("{:<8} {:>10}", cf.name, cf.count);
                    }
                }
                Err(e) => eprintln!("Error: {}", e.message()),
            }
        }
        ".dump" => {
            let index = args.first().map(|s| s.to_uppercase()).unwrap_or_else(|| "EAVT".into());
            let valid = ["EAVT", "AEVT", "AVET", "VAET"];
            if !valid.contains(&index.as_str()) {
                eprintln!("Error: index must be one of {}", valid.join(", "));
                return false;
            }
            let req = proto::DumpRequest { index };
            let stream = match rt.block_on(client.dump(req)) {
                Ok(s) => s.into_inner(),
                Err(e) => { eprintln!("Error: {}", e.message()); return false; }
            };
            use tokio_stream::StreamExt;
            let mut stream = std::pin::pin!(stream);
            let mut count = 0;
            rt.block_on(async {
                while let Some(row) = stream.next().await {
                    match row {
                        Ok(d) => {
                            let v_str = d.value.as_ref().map(proto_value_to_string).unwrap_or_else(|| "null".to_string());
                            println!("{}\t{}\t{}\t{}", d.e, d.attr, v_str, d.t);
                            count += 1;
                        }
                        Err(e) => eprintln!("Error: {}", e.message()),
                    }
                }
            });
            eprintln!("-- {} datoms", count);
        }
        _ => eprintln!("Unknown command: {}", line),
    }
    false
}

fn execute_sql(
    client: &mut EavtServiceClient<tonic::transport::Channel>,
    rt: &tokio::runtime::Runtime,
    sql: &str,
) {
    let request = proto::SqlRequest {
        query: sql.to_string(),
        params: vec![],
        as_of_us: None,
        limit: None,
    };

    let stream = match rt.block_on(client.sql(request)) {
        Ok(s) => s.into_inner(),
        Err(e) => { eprintln!("Error: {}", e.message()); return; }
    };

    use tokio_stream::StreamExt;
    let mut stream = std::pin::pin!(stream);
    rt.block_on(async {
        while let Some(row) = stream.next().await {
            match row {
                Ok(row) => {
                    let parts: Vec<String> = row.values.iter().map(proto_value_to_string).collect();
                    println!("{}", parts.join("\t"));
                }
                Err(e) => eprintln!("Error: {}", e.message()),
            }
        }
    });
}

fn proto_value_to_string(v: &proto::Value) -> String {
    match &v.kind {
        Some(proto::value::Kind::IntVal(n)) => n.to_string(),
        Some(proto::value::Kind::FloatVal(f)) => format!("{:.6}", f),
        Some(proto::value::Kind::TextVal(s)) => s.clone(),
        Some(proto::value::Kind::BoolVal(b)) => b.to_string(),
        Some(proto::value::Kind::BytesVal(b)) => hex::encode(b),
        Some(proto::value::Kind::RefVal(id)) => id.to_string(),
        None => "null".to_string(),
    }
}

fn fmt_size(n: u64) -> String {
    if n < 1024 {
        format!("{} B", n)
    } else if n < 1024 * 1024 {
        format!("{:.1} KB", n as f64 / 1024.0)
    } else if n < 1024 * 1024 * 1024 {
        format!("{:.1} MB", n as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.1} GB", n as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

fn dirs_home() -> std::path::PathBuf {
    std::env::var("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/tmp"))
}

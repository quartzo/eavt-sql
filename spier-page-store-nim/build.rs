use std::env;
use std::path::PathBuf;
use std::process::Command;

const NIM_FLAGS: &[&str] = &[
    "--app:staticlib",
    "--noMain",
    "--mm:arc",
    "--threads:on",
    "-d:release",
    "--panics:on",
    "--warning:UnusedImport:off",
    "--hint:Processing:off",
    "--noNimblePath",
    "--passC:-fPIC",
    "--passL:-fPIC",
    "--passL:-lzstd",
    "--passL:-lcrypto",
];

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let workspace_root = manifest_dir.join("..");
    let page_store_dir = workspace_root.join("nim-page-store");
    let blobstore_dir = workspace_root.join("nim-blobstore");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Track page-store sources
    for fname in &["abi.nim", "spinlock.nim", "pages.nim", "backend.nim", "all.nim"] {
        println!("cargo:rerun-if-changed={}", page_store_dir.join(fname).display());
    }
    // Track blobstore sources (all backends + journal)
    for backend in &["memory", "file", "s3", "journal"] {
        for fname in &["abi.nim", "spinlock.nim", "backend.nim", "all.nim"] {
            println!("cargo:rerun-if-changed={}", blobstore_dir.join(backend).join(fname).display());
        }
    }
    for fname in &["sha256.nim", "sigv4.nim"] {
        println!("cargo:rerun-if-changed={}", blobstore_dir.join("s3").join(fname).display());
    }

    // Track memtable sources
    let memtable_dir = workspace_root.join("nim_memtable");
    for fname in &["abi.nim", "spinlock.nim", "backend.nim", "all.nim"] {
        println!("cargo:rerun-if-changed={}", memtable_dir.join(fname).display());
    }

    if which("nim").is_none() {
        panic!(
            "`nim` not found in PATH. Install Nim >= 2.0.14 first:\n  \
             Debian/Ubuntu: sudo apt install nim\n  \
             Arch: sudo pacman -S nim\n  \
             or:    curl https://nim-lang.org/choosenim/init.sh -LsSf | sh"
        );
    }

    let src = page_store_dir.join("all.nim");
    let out_lib = out_dir.join("libnim_page_store.a");
    let nimcache = out_dir.join("nimcache");

    let blobstore_import_path = blobstore_dir.to_string_lossy().to_string();

    let mut cmd = Command::new("nim");
    cmd.arg("c")
        .args(NIM_FLAGS)
        .arg(format!("--path:{}", blobstore_import_path))
        .arg(format!("--path:."))
        .arg(format!("--out:{}", out_lib.display()))
        .arg(format!("--nimcache:{}", nimcache.display()))
        .arg(&src)
        .current_dir(&workspace_root);

    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("failed to invoke `nim c`: {}", e));
    if !status.success() {
        panic!("`nim c` failed (see output above)");
    }

    // Compile all Nim backends into a single archive.

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=nim_page_store");
    println!("cargo:rustc-link-lib=dylib=pthread");
    println!("cargo:rustc-link-lib=dylib=zstd");
    println!("cargo:rustc-link-lib=dylib=crypto");
}

fn which(cmd: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate = dir.join(cmd);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

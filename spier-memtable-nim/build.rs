// build.rs — compiles the Nim memtable backend (persistent treap) into a single
// static library `libnim_memtable.a` and links it into this crate.
//
// The backend is self-contained (owns its own `abi.nim` / `spinlock.nim`), so
// there is exactly one archive. Under `--mm:arc --threads:off` the Nim runtime
// symbols are private to the compilation unit; no `objcopy --weaken` dance is
// needed (only one archive, no cross-archive symbol collision).

use std::env;
use std::path::PathBuf;
use std::process::Command;

const NIM_FLAGS: &[&str] = &[
    "--app:staticlib",
    "--noMain",
    "--mm:arc",
    "-d:release",
    "--panics:on",
    "--warning:UnusedImport:off",
    "--hint:Processing:off",
    "--noNimblePath",
    "--passC:-fPIC",
    "--passL:-fPIC",
];

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let nim_dir = manifest_dir.join("..").join("nim-memtable");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    for fname in &["abi.nim", "spinlock.nim", "backend.nim", "all.nim"] {
        let p = nim_dir.join(fname);
        println!("cargo:rerun-if-changed={}", p.display());
    }

    if which("nim").is_none() {
        panic!(
            "`nim` not found in PATH. Install Nim >= 2.0.14 first:\n  \
             Debian/Ubuntu: sudo apt install nim\n  \
             Arch: sudo pacman -S nim\n  \
             or:    curl https://nim-lang.org/choosenim/init.sh -LsSf | sh"
        );
    }

    let src = nim_dir.join("all.nim");
    let out_lib = out_dir.join("libnim_memtable.a");
    let nimcache = out_dir.join("nimcache_memtable");

    let mut cmd = Command::new("nim");
    cmd.arg("c")
        .args(NIM_FLAGS)
        .arg(format!("--out:{}", out_lib.display()))
        .arg(format!("--nimcache:{}", nimcache.display()))
        .arg(&src)
        .current_dir(&nim_dir);

    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("failed to invoke `nim c` for memtable: {}", e));
    if !status.success() {
        panic!("`nim c` failed for memtable backend (see output above)");
    }

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=nim_memtable");

    // pthread: required by spinlock.nim (raw pthread_mutex_t binding).
    println!("cargo:rustc-link-lib=dylib=pthread");
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

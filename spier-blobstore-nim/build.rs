// build.rs — compiles the 3 Nim blobstore backends (memory / file / s3) into
// 3 separate static libraries and links all of them into this crate.
//
// Why 3 `.a`s instead of one: the user wants true per-backend modularity at
// the build-artifact level. Each backend owns its own `abi.nim` / `spinlock.nim`
// and exports symbols prefixed with `nim_blob_<backend>_*`. The Nim runtime
// symbols are duplicated across the 3 `.a`s but the linker picks the first
// definition; no duplicate-symbol conflict arises because Nim runtime symbols
// are either weak or kept private to each compilation unit.

use std::env;
use std::path::PathBuf;
use std::process::Command;

const NIM_FLAGS: &[&str] = &[
    "--app:staticlib",
    "--noMain",
    "--mm:arc",
    // NOTE: deliberately --threads:off. The backends implement their own
    // raw pthread_mutex locking (spinlock.nim) so we don't need Nim's
    // std/locks (which requires --threads:on + emits TLS that breaks
    // shared-lib linking for the PyO3 cdylib).
    "-d:release",
    "--panics:on",
    "--warning:UnusedImport:off",
    "--hint:Processing:off",
    "--noNimblePath",
    // PIC: required so the static lib can be linked into a shared library
    // (cdylib, e.g. the PyO3 .so).
    "--passC:-fPIC",
    "--passL:-fPIC",
];

struct Backend {
    name: &'static str,
    extra_passl: &'static [&'static str],
}

const BACKENDS: &[Backend] = &[
    Backend { name: "memory", extra_passl: &[] },
    Backend { name: "file",   extra_passl: &[] },
    Backend { name: "s3",     extra_passl: &["--passL:-lcrypto"] },
];

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let nim_dir = manifest_dir.join("..").join("nim-blobstore");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    // Track every Nim source per backend (each backend owns its own copies).
    for b in BACKENDS {
        for fname in &["abi.nim", "spinlock.nim", "backend.nim", "all.nim"] {
            let p = nim_dir.join(b.name).join(fname);
            println!("cargo:rerun-if-changed={}", p.display());
        }
    }
    // s3 has extra source files.
    for fname in &["sha256.nim", "sigv4.nim"] {
        let p = nim_dir.join("s3").join(fname);
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

    for b in BACKENDS {
        let src = nim_dir.join(b.name).join("all.nim");
        let out_lib = out_dir.join(format!("libnim_blobstore_{}.a", b.name));
        let nimcache = out_dir.join(format!("nimcache_{}", b.name));

        let mut cmd = Command::new("nim");
        cmd.arg("c")
            .args(NIM_FLAGS)
            .args(b.extra_passl)
            .arg(format!("--out:{}", out_lib.display()))
            .arg(format!("--nimcache:{}", nimcache.display()))
            .arg(&src)
            .current_dir(&nim_dir);

        let status = cmd
            .status()
            .unwrap_or_else(|e| panic!("failed to invoke `nim c` for {}: {}", b.name, e));
        if !status.success() {
            panic!("`nim c` failed for {} backend (see output above)", b.name);
        }

        // Each `.a` embeds its own copy of the Nim runtime (system.nim,
        // tables.nim, etc.). When the 3 archives are linked into one Rust
        // binary, their strong runtime symbols collide. Weakening all defined
        // globals lets the linker silently pick the first definition.
        weaken_archive(&out_lib);

        println!("cargo:rustc-link-search=native={}", out_dir.display());
        println!("cargo:rustc-link-lib=static=nim_blobstore_{}", b.name);
    }

    // pthread: required by spinlock.nim (raw pthread_mutex_t binding).
    println!("cargo:rustc-link-lib=dylib=pthread");
    // crypto: required by s3/sha256.nim (OpenSSL EVP_Digest + HMAC).
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

/// Weaken all defined global symbols in a static archive. Lets multiple
/// archives that embed the same runtime (e.g. Nim's system.nim) be linked
/// together without duplicate-symbol errors.
fn weaken_archive(archive: &PathBuf) {
    // Three equivalent tools across toolchains. Try them in order.
    for tool in ["llvm-objcopy", "objcopy", "gobjcopy"] {
        if which(tool).is_none() {
            continue;
        }
        let status = Command::new(tool)
            .arg("--weaken")
            .arg(archive)
            .status()
            .unwrap_or_else(|e| panic!("failed to invoke {tool} --weaken: {e}"));
        if !status.success() {
            panic!("`{tool} --weaken` failed on {}", archive.display());
        }
        return;
    }
    panic!(
        "none of `llvm-objcopy`, `objcopy`, `gobjcopy` found in PATH — needed to weaken Nim runtime symbols across the 3 blobstore archives"
    );
}

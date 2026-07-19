fn main() {
    // Force linking of the native Nim library for cdylib targets.
    // cargo doesn't propagate `cargo:rustc-link-lib` from transitive
    // dependencies to cdylib/staticlib crate types.
    // The search path is already provided by spier-page-store-nim.
    println!("cargo:rustc-link-lib=static=nim_page_store");
    println!("cargo:rustc-link-lib=dylib=pthread");
    println!("cargo:rustc-link-lib=dylib=zstd");
    println!("cargo:rustc-link-lib=dylib=crypto");
}

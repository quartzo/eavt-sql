fn main() {
    // Force linking of the native Nim library for cdylib targets.
    println!("cargo:rustc-link-lib=static=nim_page_store");
    println!("cargo:rustc-link-lib=dylib=pthread");
    println!("cargo:rustc-link-lib=dylib=zstd");
    println!("cargo:rustc-link-lib=dylib=crypto");
}

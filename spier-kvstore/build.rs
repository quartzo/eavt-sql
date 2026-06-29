fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();

    // Host-side code for storage-layer interfaces consumed internally
    // by this crate (tower clients + traits for calling sub-spiers).
    ctx.build_host("src/idl/blobstore.dspi");
    ctx.build_host("src/idl/journal.dspi");
    ctx.build_host("src/idl/memtable.dspi");

    // Spier-side code for the KVStore interface itself.
    ctx.build_spier("src/idl/kvstore.dspi");
}

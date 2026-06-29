fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    ctx.build_spier("../spier-kvstore/src/idl/blobstore.dspi");
}

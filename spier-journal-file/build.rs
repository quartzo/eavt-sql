fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    ctx.build_spier("../spier-kvstore/src/idl/journal.dspi");
    ctx.build_python(
        "../spier-kvstore/src/idl/journal.dspi",
        "generated/spier_journal_file.py",
    );
}

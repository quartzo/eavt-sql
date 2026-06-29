fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    // Pre-register shared types (Value, ValueType, opaque structs) so that
    // transactor.dspi's build skips their definitions. The spier imports
    // them from dynspire-commons instead.
    ctx.build_spier("src/register_types.dspi");
    ctx.build_spier("../dynspire-commons/src/transactor.dspi");
    ctx.build_python(
        "../dynspire-commons/src/transactor.dspi",
        "generated/spier_transactor.py",
    );
}

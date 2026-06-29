fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    ctx.build_spier("../dynspire-commons/src/datalog.dspi");
    ctx.build_python(
        "../dynspire-commons/src/datalog.dspi",
        "generated/spier_datalog.py",
    );
}

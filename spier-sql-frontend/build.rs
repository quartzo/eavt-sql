fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    ctx.build_spier("../dynspire-commons/src/sql_frontend.dspi");
    ctx.build_python(
        "../dynspire-commons/src/sql_frontend.dspi",
        "generated/spier_sql_frontend.py",
    );
}

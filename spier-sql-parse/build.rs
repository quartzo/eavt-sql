fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();
    ctx.build_spier("../dynspire-commons/src/sql_parse.dspi");
    ctx.build_python(
        "../dynspire-commons/src/sql_parse.dspi",
        "generated/spier_sql_parse.py",
    );
}

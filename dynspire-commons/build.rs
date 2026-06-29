fn main() {
    let mut ctx = dynspire_codegen::BuildContext::new();

    // KVStore host code lives here (DynSpireKVStore tower client used by
    // spier-transactor).  The .dspi file is owned by spier-kvstore.
    ctx.build_host("../spier-kvstore/src/idl/kvstore.dspi");

    // Order matters: transactor must come before query_engine so that
    // Value/ValueType enums are emitted in the transactor module and
    // imported via `use` in query_engine.
    ctx.build_host("src/transactor.dspi");
    ctx.build_host("src/sql_parse.dspi");
    ctx.build_host("src/datalog.dspi");
    ctx.build_host("src/sql_frontend.dspi");
    ctx.build_host("src/planner.dspi");
    ctx.build_host("src/compiler.dspi");
    ctx.build_host("src/query_engine.dspi");
}

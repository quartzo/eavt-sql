fn main() {
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["../proto/eavt.proto"], &["../proto"])
        .unwrap();
}

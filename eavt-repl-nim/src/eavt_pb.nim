## Generated Nim types + gRPC service path constants for eavt.proto.
## importProto3 parses ../proto/eavt.proto at compile time (path resolved
## relative to this file) and emits Value/SqlRow/SqlRequest/... plus the
## EavtService*Path constants. No hand-written protobuf.
import grpc

importProto3("../proto/eavt.proto")

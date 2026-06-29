import grpc
from collections.abc import Generator

from eavt_client import eavt_pb2 as pb
from eavt_client import eavt_pb2_grpc as grpc_pb


class EavtClient:
    def __init__(self, addr: str):
        self.channel = grpc.insecure_channel(addr)
        self.stub = grpc_pb.EavtServiceStub(self.channel)

    def close(self):
        self.channel.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def execute(self, query: str, *params, **kw) -> list[tuple]:
        request = pb.SqlRequest(
            query=query,
            params=[_to_proto_value(p) for p in params],
            as_of_us=kw.get("as_of_us"),
            limit=kw.get("limit"),
        )
        resp = self.stub.Execute(request)
        return [tuple(_from_proto_value(v) for v in row.values) for row in resp.rows]

    def sql(
        self,
        query: str,
        *params,
        as_of_us: int | None = None,
        limit: int | None = None,
    ) -> Generator[tuple, None, None]:
        request = pb.SqlRequest(
            query=query,
            params=[_to_proto_value(p) for p in params],
            as_of_us=as_of_us,
            limit=limit,
        )
        for row in self.stub.Sql(request):
            yield tuple(_from_proto_value(v) for v in row.values)

    def sql1(self, query: str, *params, **kw) -> tuple | None:
        return next(self.sql(query, *params, limit=1, **kw), None)

    def flush(self):
        self.execute("FLUSH")

    def status(self) -> dict:
        rows = self.execute("STATUS")
        row = rows[0] if rows else ("", "")
        return {"db_path": row[0], "storage_mode": row[1]}


def _to_proto_value(v) -> pb.Value:
    if isinstance(v, bool):
        return pb.Value(bool_val=v)
    if isinstance(v, int):
        return pb.Value(int_val=v)
    if isinstance(v, float):
        return pb.Value(float_val=v)
    if isinstance(v, str):
        return pb.Value(text_val=v)
    if isinstance(v, bytes):
        return pb.Value(bytes_val=v)
    raise TypeError(f"unsupported type: {type(v)}")


def _from_proto_value(v: pb.Value) -> int | float | str | bool | bytes | None:
    kind = v.WhichOneof("kind")
    if kind == "int_val":
        return v.int_val
    if kind == "float_val":
        return v.float_val
    if kind == "text_val":
        return v.text_val
    if kind == "bool_val":
        return v.bool_val
    if kind == "bytes_val":
        return v.bytes_val
    if kind == "ref_val":
        return v.ref_val
    return None

/// Read-only schema and cardinality abstraction used by the compiler/planner
/// for cost estimation. Implementors are typically adapters over the transactor.
pub trait CompileStats: Send + Sync {
    fn lookup_attr(&self, name: &str) -> Option<u32>;

    fn estimate_index_size(&self, index: &str, bound: &[u64]) -> f64;

    fn partition_id_for(&self, name: &str) -> Option<u64>;

    fn is_ref_attr(&self, attr_name: &str) -> bool;

    fn is_indexed_attr(&self, attr_name: &str) -> bool;
}

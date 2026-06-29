use crate::transactor::{TransactorEngine, DynSpireTransactor};
use crate::compiler::CompileStats;
use crate::transactor::resolver_consts::DB_TYPE_REF;

impl CompileStats for DynSpireTransactor {
    fn lookup_attr(&self, name: &str) -> Option<u32> {
        TransactorEngine::lookup_attr(self, name).ok().flatten()
    }

    fn estimate_index_size(&self, index: &str, bound: &[u64]) -> f64 {
        let cf = crate::transactor::keys::cf_for_index(index);
        let cf_id = crate::transactor::keys::cf_name_to_id(cf);
        let idx_order = crate::transactor::keys::index_order(index);
        let mut prefix = Vec::new();
        for (i, pos) in idx_order.iter().enumerate() {
            if i >= bound.len() {
                break;
            }
            let val = bound[i];
            if *pos == "a" {
                prefix.extend_from_slice(&(val as u32).to_be_bytes());
            } else {
                prefix.extend_from_slice(&val.to_be_bytes());
            }
        }
        let end = if prefix.is_empty() {
            vec![0xFF; 64]
        } else {
            let mut e = prefix.clone();
            e.extend_from_slice(&[0xFF; 32]);
            e
        };
        TransactorEngine::approximate_sizes(self, cf_id, &prefix, &end)
            .unwrap_or(0) as f64
    }

    fn partition_id_for(&self, name: &str) -> Option<u64> {
        TransactorEngine::partition_id_for(self, name).ok().flatten()
    }

    fn is_ref_attr(&self, attr_name: &str) -> bool {
        if let Some(aid) = TransactorEngine::lookup_attr(self, attr_name).ok().flatten() {
            TransactorEngine::value_type_for(self, aid)
                .ok().flatten()
                .map(|vt| vt as u32 == DB_TYPE_REF)
                .unwrap_or(false)
        } else {
            false
        }
    }
}

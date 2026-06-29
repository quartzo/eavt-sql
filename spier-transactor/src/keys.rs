pub use dynspire_commons::transactor::keys::*;

use crate::resolver::Resolver;

/// Convenience wrapper that uses a Resolver for value-type lookup.
pub fn unpack_key(cf: &str, key: &[u8], resolver: &Resolver) -> RawDatom {
    unpack_key_with_vt(cf, key, |aid| resolver.value_type_for(aid))
}

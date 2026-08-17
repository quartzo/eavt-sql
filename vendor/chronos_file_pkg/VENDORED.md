# Vendored: chronos-file

Upstream: https://github.com/fox0430/chronos-file
Version:  0.3.0 (commit 82abb04, "Bump to 0.3.0 (#23)")
License:  MIT (see LICENSE)

Vendored to keep the durability-critical WAL dependency immutable to
upstream churn. Update by re-copying from upstream and re-recording the
commit here. Imports use `pkg/chronos`, resolved by the project's nimble
dependency; `--path:"vendor"` is set in the repo nim.cfg.

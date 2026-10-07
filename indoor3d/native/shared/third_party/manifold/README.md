# Manifold dependency

The validity native target intentionally keeps Manifold out of the runtime Core target.

Before building `indoor_gml_validity_native`, vendor the same Manifold package used by
`UlolSkpProject/SeoulSpace-Verify` into this directory so these paths exist:

- `include/manifold/manifold.h`
- `include/manifold/mesh.h`
- `lib/manifold.lib`

The binary dependency is not copied by the automated source refactor because this change
must not generate or mutate native binary artifacts.

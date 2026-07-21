# frozen_string_literal: true

require 'fileutils'

ROOT = File.expand_path('..', __dir__)
LVN_DIR = File.join(ROOT, 'indoor3d/application/local_vertex_normalizer')

METHOD_RANGES = {
  'legacy_kernel.rb' => [
    [51, 60], [97, 129], [134, 142], [146, 306],
    [574, 613], [615, 654], [759, 764], [776, 837],
    [912, 969], [971, 975], [977, 990], [992, 1006],
    [1018, 1036], [1752, 1790], [3318, 3367], [3379, 3383],
    [3602, 3688], [3690, 3717], [3738, 3752], [3754, 3775],
    [3777, 3804]
  ],
  'coplanar_shared_edge_groups.rb' => [[47, 60]],
  'rebuild_repair_v2.rb' => [[283, 326], [328, 369]],
  'source_face_boundary_constraints_v2.rb' => [
    [53, 117], [123, 142], [149, 225],
    [227, 233], [235, 248], [250, 257]
  ],
  'source_face_boundary_common_refinement_v2.rb' => [[423, 426]]
}.freeze

OLD_MARKERS = {
  'legacy_kernel.rb' => 'def normalize_entity(entity)',
  'coplanar_shared_edge_groups.rb' => 'def coplanar_edge_metrics(edge)',
  'rebuild_repair_v2.rb' => 'def normalized_surface_descriptor(triangle_records)',
  'source_face_boundary_constraints_v2.rb' => 'def source_face_boundary_subdivision_inventory(entities)',
  'source_face_boundary_common_refinement_v2.rb' => 'def subdivide_source_face_boundary_loop(*)'
}.freeze

def remove_line_ranges(path, ranges)
  lines = File.readlines(path)
  ranges.sort.reverse_each do |first_line, last_line|
    lines.slice!(first_line - 1, last_line - first_line + 1)
  end
  File.write(path, lines.join)
end

def replace_if_present!(path, before, after)
  source = File.read(path)
  return false unless source.include?(before)

  File.write(path, source.sub(before, after))
  true
end

def collapse_blank_lines!(path)
  return unless File.file?(path)

  source = File.read(path).gsub(/\n{3,}/, "\n\n")
  File.write(path, source)
end

def indent_block(text, spaces = 8)
  prefix = ' ' * spaces
  text.lines.map { |line| line.strip.empty? ? line : prefix + line }.join
end

METHOD_RANGES.each do |filename, ranges|
  path = File.join(LVN_DIR, filename)
  marker = OLD_MARKERS.fetch(filename)
  remove_line_ranges(path, ranges) if File.read(path).include?(marker)
end

legacy = File.join(LVN_DIR, 'legacy_kernel.rb')
collapse_blank_lines!(legacy)
replace_if_present!(legacy, '        STRICT_COPLANAR_TOLERANCE_MM = 0.000001',
                    '        STRICT_COPLANAR_TOLERANCE_MM = 0.0001')
replace_if_present!(legacy, "        MAX_COLLINEAR_REPAIRS = 1_000\n", '')
replace_if_present!(legacy, "        class << self\n\n          def normalized?",
                    "        class << self\n          def normalized?")
replace_if_present!(
  legacy,
  indent_block(<<~'BEFORE'),
    # Returns true when every definition-local vertex lies on the requested
    # millimetre grid and no two topologically distinct vertices occupy the
    # same grid coordinate.
    #
    # This is intentionally a fast coordinate/uniqueness predicate. It is not
    # a complete solid-validity or cleanup predicate.

    # Rebuilds one manifold solid on the requested local-coordinate grid.
    # The complete reconstruction owns one SketchUp operation so every
    # mutation, including make_unique, is rolled back on failure.

    private
  BEFORE
  "        private\n"
)
replace_if_present!(
  legacy,
  indent_block(<<~'BEFORE'),
    # Builds the normalized shell and applies only the strict coplanar cleanup.
    # If strict cleanup damages topology, the geometry is rebuilt without it.

    def empty_coplanar_cleanup_report(fallback_reason: nil)
  BEFORE
  "        def empty_coplanar_cleanup_report(fallback_reason: nil)\n"
)
replace_if_present!(
  legacy,
  indent_block(<<~'BEFORE'),
    # Reconstructs every connected, exact coplanar triangle patch from its
    # preserved boundary constraints. The source triangulation is treated as
    # topology only: none of its internal diagonals survive. This avoids
    # carrying a flipped or almost-zero SketchUp mesh triangle into the
    # normalized shell.

    def exact_coplanar_patch_retriangulation_required?(patch)
  BEFORE
  indent_block(<<~'AFTER')
    # Returns true when an exact coplanar patch must be rebuilt instead of
    # preserving its current triangulation.
    def exact_coplanar_patch_retriangulation_required?(patch)
  AFTER
)
replace_if_present!(
  legacy,
  indent_block(<<~'BEFORE'),
    # SketchUp can create a triangular overlap cap while normalized faces are
    # added. The cap is removed only when doing so reduces topology anomalies.

    def face_record(face)
  BEFORE
  "        def face_record(face)\n"
)
replace_if_present!(legacy, '        # Coplanar, collinear and orientation cleanup',
                    '        # Coplanar and orientation cleanup')
collapse_blank_lines!(legacy)

runtime_fixes = File.join(LVN_DIR, 'runtime_regression_fixes_v2.rb')
replace_if_present!(
  runtime_fixes,
  indent_block(<<~'BEFORE'),
    remove_const(:STRICT_COPLANAR_TOLERANCE_MM) if
      const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)
    STRICT_COPLANAR_TOLERANCE_MM = 0.00001

  BEFORE
  ''
)

collapse_blank_lines!(File.join(LVN_DIR, 'coplanar_shared_edge_groups.rb'))
collapse_blank_lines!(File.join(LVN_DIR, 'source_face_boundary_constraints_v2.rb'))

common_refinement = File.join(LVN_DIR, 'source_face_boundary_common_refinement_v2.rb')
replace_if_present!(
  common_refinement,
  indent_block(<<~'BEFORE'),
    # The previous point-proximity implementation is intentionally disabled.
    # A lone nearby vertex does not prove that two Face boundaries overlap.
  BEFORE
  ''
)
collapse_blank_lines!(common_refinement)

entrypoint = File.join(ROOT, 'indoor3d/application/local_vertex_normalizer.rb')
replace_if_present!(entrypoint,
                    "require_relative 'local_vertex_normalizer/coplanar_tolerance_policy_v2'\n", '')
replace_if_present!(
  entrypoint,
  <<~'BEFORE',
    # The geometry kernel is kept separate from the v2 orchestration policy. Loading
    # this file installs the complete LocalVertexNormalizer implementation in the
    # required order: legacy geometric primitives, safe coplanar edge grouping, the
    # v2 normalization pipeline, runtime regression fixes from integration runs,
    # the production coplanar-tolerance policy, Face-local topology-preserving grid
    # targets, global shell-embedding grid targets, source-Face provenance,
    # overlap-backed common refinement of source Face boundaries, unique source-key
    # insertion ownership per Face loop, the bridge that exposes those refined loops
    # to grid-target topology planning, the bounded multi-point target search, the
    # final incidence-1 chord-chain conformity repair, the post-rebuild surface hard
    # checkpoint, preservation of a rebuilt surface that already matches the
    # validated in-memory surface, then stepwise surface-preserving entity repair.
  BEFORE
  "# Loads the LocalVertexNormalizer kernel and its v2 policies in dependency order.\n"
)

main_test = File.join(ROOT, 'test/test_local_vertex_normalizer.rb')
source = File.read(main_test)
test_start = source.index(
  "        def test_only_shared_edges_between_faces_on_the_same_exact_axis_plane_are_mergeable\n"
)
if test_start
  test_end = source.index(
    "        def test_exact_duplicate_mesh_triangles_are_canonicalized_before_manifold_validation\n",
    test_start
  )
  raise 'Obsolete axis-plane merge test has no following test boundary' unless test_end

  File.write(main_test, source[0...test_start] + source[test_end..])
end

policy_smoke = File.join(ROOT, 'test/local_vertex_normalizer_v2_policy_smoke.rb')
replace_if_present!(
  policy_smoke,
  <<~'BEFORE',
    # Standalone policy smoke test. This does not require SketchUp and verifies the
    # two invariants that caused the v2 review regressions:
    #   1. one corner vertex retains independent X/Y/Z plane constraints;
    #   2. surface equivalence is independent of a coplanar patch's diagonal.
  BEFORE
  "# Standalone axis-constraint policy smoke test. This does not require SketchUp.\n"
)
replace_if_present!(policy_smoke,
                    "require_relative '../indoor3d/application/local_vertex_normalizer/rebuild_repair_v2'\n", '')
source = File.read(policy_smoke)
fixture_start = source.index("\nsquare_diagonal_ac = [")
if fixture_start
  fixture_end = source.index("\nputs 'LocalVertexNormalizer v2 policy smoke test: OK'", fixture_start)
  raise 'Obsolete surface descriptor fixture has no trailing output statement' unless fixture_end

  File.write(policy_smoke, source[0...fixture_start] + source[fixture_end..])
end

runtime_smoke = File.join(ROOT, 'test/local_vertex_normalizer_v2_runtime_regression_smoke.rb')
replace_if_present!(
  runtime_smoke,
  'STRICT_COPLANAR_TOLERANCE_MM = 0.00001 unless const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)',
  'STRICT_COPLANAR_TOLERANCE_MM = 0.0001 unless const_defined?(:STRICT_COPLANAR_TOLERANCE_MM, false)'
)
replace_if_present!(
  runtime_smoke,
  <<~'BEFORE',
    unless klass::STRICT_COPLANAR_TOLERANCE_MM == 0.00001
      raise 'strict coplanar tolerance was not raised to 0.00001 mm'
    end
  BEFORE
  <<~'AFTER'
    unless klass::STRICT_COPLANAR_TOLERANCE_MM == 0.0001
      raise 'unexpected strict coplanar tolerance'
    end
  AFTER
)

[
  File.join(LVN_DIR, 'coplanar_tolerance_policy_v2.rb'),
  File.join(ROOT, 'test/local_vertex_normalizer_v2_coplanar_tolerance_policy_smoke.rb'),
  File.join(ROOT, '.github/workflows/lvn-dead-code-audit.yml'),
  __FILE__
].each { |path| FileUtils.rm_f(path) }

puts 'LocalVertexNormalizer dead code cleanup applied'

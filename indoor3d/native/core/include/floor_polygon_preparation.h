#pragma once

#include "geometry_data.h"

#include <cstddef>
#include <optional>
#include <vector>

namespace IndoorGMLAdjacencyNative
{
namespace FloorPartition
{
// Phase 1/2 only. Deliberately independent of the shared CellData geometry
// protocol, Triangle BVH, State placement and runtime Graph. The original
// SketchUp Face data remains immutable; later phases may consume these values.
struct Vec2
{
    double x = 0.0;
    double y = 0.0;
};

struct Frame
{
    Vec3 origin;
    Vec3 u;
    Vec3 v;
    Vec3 n;

    Vec2 project(const Vec3& point) const;
    Vec3 lift(const Vec2& point) const;
};

struct Bounds2
{
    Vec2 minimum;
    Vec2 maximum;
};

struct NormalizedLoop
{
    // Outer: CCW; holes: CW in the face-local (u,v) coordinate system.
    // The first point is the lexicographically smallest normalized vertex.
    std::vector<Vec2> points;
    std::vector<std::size_t> source_vertex_indices;
    Bounds2 bounds;
    double signed_area = 0.0;
    std::size_t source_loop_index = 0; // 0=outer, 1..N=original hole indices
    bool hole = false;
};

struct NormalizedFace
{
    Frame frame;
    Plane plane; // authoritative SketchUp plane, normalized and propagated
    NormalizedLoop outer;
    std::vector<NormalizedLoop> holes;
};

enum class PreparationError
{
    None,
    InvalidTolerance,
    InvalidNormal,
    InvalidOuterLoop,
    InvalidInnerLoop,
    NonPlanarLoop,
    DegenerateLoop
};

struct PreparationResult
{
    std::optional<NormalizedFace> face;
    PreparationError error = PreparationError::None;
    std::size_t source_loop_index = 0;

    explicit operator bool() const { return face.has_value(); }
};

// Pure boundary normalization: NO changes to FaceData, mesh, or CellSpace.
// Plane Ax+By+Cz+D=0 is authoritative; its coefficients and vertices
// must already be expressed in the SAME SketchUp parent coordinates.
// tolerance is a 3D length in SketchUp/native units (inches).
PreparationResult prepare(
    const Plane& plane,
    const std::vector<Vec3>& outer_loop,
    const std::vector<std::vector<Vec3>>& inner_loops,
    double tolerance
);

// Legacy/synthetic input ONLY. Modern V5 production calls prepare(Plane)
// and never reconstructs D from a Loop vertex.
PreparationResult prepare(
    const Vec3& normal,
    const std::vector<Vec3>& outer_loop,
    const std::vector<std::vector<Vec3>>& inner_loops,
    double tolerance
);

enum class LoopKind { Outer, Inner };

struct SplitCandidate
{
    LoopKind kind = LoopKind::Outer;
    std::size_t source_loop_index = 0; // 0=outer, 1..N=original hole indices
    std::size_t vertex_index = 0;      // index in normalized points
    std::size_t source_vertex_index = 0;
    Vec2 origin;
    Vec2 primary_direction;           // unit angular bisector
    bool bidirectional = false;       // true for inner loops
    bool hole_fallback = false;       // use first hole vertex if no threshold hit
    double signed_turn_degrees = 0.0;
};

struct CandidateResult
{
    std::vector<SplitCandidate> candidates;
    bool valid_settings = false;
};

// Phase 2 ONLY: a list of geometric rays in deterministic Outer -> Inner
// order, without ray/edge intersection or split validation.
// Accumulation resets INDEPENDENTLY for each ring; never carries over
// from outer to holes or between holes. A second cyclic pass settles
// the outer ring's wrap-around negative turn run.
CandidateResult propose_splits(
    const NormalizedFace& face,
    double cumulative_reflex_degrees = 30.0,
    double angular_noise_degrees = 0.25
);

} // namespace FloorPartition
} // namespace IndoorGMLAdjacencyNative

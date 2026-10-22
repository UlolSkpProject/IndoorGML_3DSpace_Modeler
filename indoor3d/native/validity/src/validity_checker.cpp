#include "validity_checker.h"

#include "exact_face_adjacency.h"
#include "overlap_thickness.h"

#include <manifold/mesh.h>

#include <cmath>
#include <cstddef>
#include <vector>

namespace IndoorGMLValidityNative
{
ValidityResult check_overlap_701(
    const manifold::Manifold& first,
    const manifold::Manifold& second,
    double thickness_tolerance
)
{
    ValidityResult result;
    result.code = VALIDITY_CODE_OVERLAP;

    manifold::Manifold intersection = first ^ second;
    if (intersection.Status()!=manifold::Manifold::Error::NoError)
    {
        result.status=ValidityStatus::Uncertain;
        return result;
    }
    if (intersection.IsEmpty())
    {
        result.status=ValidityStatus::NoOverlap;
        return result;
    }

    const double volume=intersection.Volume();
    if (!std::isfinite(volume))
    {
        result.status=ValidityStatus::Uncertain;
        return result;
    }
    if (!(volume > 0.0))
    {
        result.status=ValidityStatus::NoOverlap;
        return result;
    }

    result.volume=volume;
    const std::vector<manifold::Manifold> components=intersection.Decompose();
    result.component_count=components.size();

    const ThicknessResult thickness=
        classify_overlap_thickness(intersection,thickness_tolerance);
    if (thickness==ThicknessResult::Thin)
    {
        result.status=ValidityStatus::ThinOverlap;
        return result;
    }
    if (thickness!=ThicknessResult::Thick)
    {
        result.status=ValidityStatus::Uncertain;
        return result;
    }

    result.status=ValidityStatus::Overlap;
    const manifold::MeshGL64 mesh=intersection.GetMeshGL64();
    result.vertices.reserve(static_cast<std::size_t>(mesh.NumVert()));
    for (std::size_t index=0; index<static_cast<std::size_t>(mesh.NumVert()); ++index)
    {
        const auto point=mesh.GetVertPos(index);
        result.vertices.push_back({point.x,point.y,point.z});
    }
    result.triangles.reserve(mesh.triVerts.size()/3);
    for (std::size_t offset=0; offset+2<mesh.triVerts.size(); offset+=3)
    {
        result.triangles.push_back({
            static_cast<std::uint64_t>(mesh.triVerts[offset]),
            static_cast<std::uint64_t>(mesh.triVerts[offset+1]),
            static_cast<std::uint64_t>(mesh.triVerts[offset+2])
        });
    }
    return result;
}

ValidityResult check_adjacency_704(
    const IndoorGMLAdjacencyNative::CellData& first,
    const IndoorGMLAdjacencyNative::CellData& second,
    double length_tolerance,
    double normal_tolerance
)
{
    ValidityResult result;
    result.code=VALIDITY_CODE_ADJACENCY;
    const auto adjacency=IndoorGMLAdjacencyNative::analyze_pair(
        first,second,length_tolerance,normal_tolerance
    );
    if (!adjacency)
    {
        result.status=ValidityStatus::NotAdjacent;
        return result;
    }
    result.status=ValidityStatus::Adjacent;
    result.axis=adjacency->axis;
    return result;
}
} // namespace IndoorGMLValidityNative

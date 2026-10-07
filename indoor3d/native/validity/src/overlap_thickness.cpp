#include "overlap_thickness.h"

#include <manifold/mesh.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <vector>

namespace
{
using manifold::Manifold;
using manifold::MeshGL64;
using manifold::vec3;
using IndoorGMLValidityNative::ThicknessResult;

constexpr int PROBE_SPHERE_SEGMENTS = 32;

struct ProbePair
{
    Manifold inner;
    Manifold outer;
};

vec3 subtract(const vec3& a, const vec3& b)
{
    return vec3(a.x-b.x, a.y-b.y, a.z-b.z);
}

vec3 cross(const vec3& a, const vec3& b)
{
    return vec3(
        a.y*b.z-a.z*b.y,
        a.z*b.x-a.x*b.z,
        a.x*b.y-a.y*b.x
    );
}

double dot(const vec3& a, const vec3& b)
{
    return a.x*b.x+a.y*b.y+a.z*b.z;
}

double length(const vec3& value)
{
    return std::sqrt(dot(value,value));
}

double max_vertex_radius(const MeshGL64& mesh)
{
    double radius = 0.0;
    for (std::size_t index=0; index<static_cast<std::size_t>(mesh.NumVert()); ++index)
        radius = std::max(radius, length(mesh.GetVertPos(index)));
    return radius;
}

double min_face_plane_distance(const MeshGL64& mesh)
{
    double distance = std::numeric_limits<double>::infinity();
    for (std::size_t offset=0; offset+2<mesh.triVerts.size(); offset+=3)
    {
        const vec3 first = mesh.GetVertPos(mesh.triVerts[offset]);
        const vec3 second = mesh.GetVertPos(mesh.triVerts[offset+1]);
        const vec3 third = mesh.GetVertPos(mesh.triVerts[offset+2]);
        const vec3 normal = cross(subtract(second,first), subtract(third,first));
        const double normal_length = length(normal);
        if (!(normal_length > 0.0) || !std::isfinite(normal_length)) continue;
        const double plane_distance = std::abs(dot(normal,first)) / normal_length;
        if (std::isfinite(plane_distance)) distance = std::min(distance,plane_distance);
    }
    return distance;
}

ProbePair build_probe_pair(double radius)
{
    Manifold unit_sphere = Manifold::Sphere(1.0, PROBE_SPHERE_SEGMENTS);
    if (unit_sphere.Status()!=Manifold::Error::NoError || unit_sphere.IsEmpty())
        throw std::runtime_error("failed to build validity thickness sphere");

    const MeshGL64 mesh = unit_sphere.GetMeshGL64();
    const double outer_radius = max_vertex_radius(mesh);
    const double inner_radius = min_face_plane_distance(mesh);
    if (!(outer_radius>0.0) || !(inner_radius>0.0) ||
        !std::isfinite(outer_radius) || !std::isfinite(inner_radius))
        throw std::runtime_error("invalid validity thickness sphere");

    const double inner_scale = std::nextafter(radius / outer_radius, 0.0);
    const double strict_radius = std::nextafter(radius, std::numeric_limits<double>::infinity());
    const double outer_scale = std::nextafter(
        strict_radius / inner_radius,
        std::numeric_limits<double>::infinity()
    );

    ProbePair probes{
        unit_sphere.Scale(vec3(inner_scale)),
        unit_sphere.Scale(vec3(outer_scale))
    };
    if (probes.inner.Status()!=Manifold::Error::NoError ||
        probes.outer.Status()!=Manifold::Error::NoError)
        throw std::runtime_error("failed to scale validity thickness sphere");
    return probes;
}

ThicknessResult classify_component(const Manifold& component, const ProbePair& probes)
{
    if (component.Status()!=Manifold::Error::NoError) return ThicknessResult::Uncertain;
    if (component.IsEmpty()) return ThicknessResult::Thin;

    Manifold inner_erosion = component.MinkowskiDifference(probes.inner);
    if (inner_erosion.Status()!=Manifold::Error::NoError) return ThicknessResult::Uncertain;
    if (inner_erosion.IsEmpty()) return ThicknessResult::Thin;

    Manifold outer_erosion = component.MinkowskiDifference(probes.outer);
    if (outer_erosion.Status()!=Manifold::Error::NoError) return ThicknessResult::Uncertain;
    if (!outer_erosion.IsEmpty()) return ThicknessResult::Thick;
    return ThicknessResult::Uncertain;
}
} // namespace

namespace IndoorGMLValidityNative
{
ThicknessResult classify_overlap_thickness(
    const manifold::Manifold& geometry,
    double diameter_tolerance
)
{
    if (!std::isfinite(diameter_tolerance) || diameter_tolerance <= 0.0)
        throw std::invalid_argument("validity overlap tolerance must be finite and positive");
    if (geometry.Status()!=manifold::Manifold::Error::NoError)
        return ThicknessResult::Uncertain;
    if (geometry.IsEmpty()) return ThicknessResult::Thin;

    try
    {
        const ProbePair probes = build_probe_pair(diameter_tolerance * 0.5);
        const std::vector<manifold::Manifold> components = geometry.Decompose();
        if (components.empty()) return ThicknessResult::Uncertain;

        bool uncertain = false;
        for (const manifold::Manifold& component : components)
        {
            const ThicknessResult result = classify_component(component, probes);
            if (result == ThicknessResult::Thick) return ThicknessResult::Thick;
            uncertain = uncertain || result == ThicknessResult::Uncertain;
        }
        return uncertain ? ThicknessResult::Uncertain : ThicknessResult::Thin;
    }
    catch (...)
    {
        return ThicknessResult::Uncertain;
    }
}
} // namespace IndoorGMLValidityNative

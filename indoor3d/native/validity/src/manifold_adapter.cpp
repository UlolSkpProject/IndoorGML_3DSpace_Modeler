#include "manifold_adapter.h"

#include <manifold/mesh.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <utility>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

Vec3 subtract(const Vec3& a, const Vec3& b)
{
    return Vec3{a.x-b.x,a.y-b.y,a.z-b.z};
}

Vec3 cross(const Vec3& a, const Vec3& b)
{
    return Vec3{
        a.y*b.z-a.z*b.y,
        a.z*b.x-a.x*b.z,
        a.x*b.y-a.y*b.x
    };
}

double dot(const Vec3& a, const Vec3& b)
{
    return a.x*b.x+a.y*b.y+a.z*b.z;
}

std::uint64_t bits(double value)
{
    std::uint64_t result = 0;
    static_assert(sizeof(result)==sizeof(value), "double must be 64-bit");
    std::memcpy(&result,&value,sizeof(value));
    return result;
}

struct VertexKey
{
    std::uint64_t x=0,y=0,z=0;
    bool operator==(const VertexKey& other) const
    {
        return x==other.x && y==other.y && z==other.z;
    }
};

struct VertexKeyHash
{
    std::size_t operator()(const VertexKey& key) const
    {
        std::size_t seed = static_cast<std::size_t>(key.x ^ (key.x >> 32));
        seed ^= static_cast<std::size_t>(key.y ^ (key.y >> 32)) + 0x9e3779b9u + (seed<<6) + (seed>>2);
        seed ^= static_cast<std::size_t>(key.z ^ (key.z >> 32)) + 0x9e3779b9u + (seed<<6) + (seed>>2);
        return seed;
    }
};

std::uint64_t intern_vertex(
    const Vec3& point,
    std::unordered_map<VertexKey,std::uint64_t,VertexKeyHash>& indices,
    std::vector<double>& vertices
)
{
    const VertexKey key{bits(point.x),bits(point.y),bits(point.z)};
    const auto found = indices.find(key);
    if (found != indices.end()) return found->second;
    const std::uint64_t index = static_cast<std::uint64_t>(vertices.size()/3);
    indices.emplace(key,index);
    vertices.push_back(point.x);
    vertices.push_back(point.y);
    vertices.push_back(point.z);
    return index;
}
} // namespace

namespace IndoorGMLValidityNative
{
std::shared_ptr<manifold::Manifold> build_manifold(const CellData& cell)
{
    std::vector<double> vertices;
    std::vector<std::uint64_t> triangles;
    std::unordered_map<VertexKey,std::uint64_t,VertexKeyHash> indices;

    for (const FaceData& face : cell.faces)
    {
        for (const Triangle& source : face.triangles)
        {
            Vec3 a=source.points[0];
            Vec3 b=source.points[1];
            Vec3 c=source.points[2];
            if (dot(cross(subtract(b,a),subtract(c,a)),face.normal) < 0.0)
                std::swap(b,c);

            const std::uint64_t ia=intern_vertex(a,indices,vertices);
            const std::uint64_t ib=intern_vertex(b,indices,vertices);
            const std::uint64_t ic=intern_vertex(c,indices,vertices);
            if (ia==ib || ib==ic || ia==ic) continue;
            triangles.push_back(ia);
            triangles.push_back(ib);
            triangles.push_back(ic);
        }
    }

    if (vertices.empty() || triangles.empty()) return nullptr;

    manifold::MeshGL64 mesh;
    mesh.numProp=3;
    mesh.vertProperties=std::move(vertices);
    mesh.triVerts=std::move(triangles);

    auto result=std::make_shared<manifold::Manifold>(mesh);
    if (result->Status()!=manifold::Manifold::Error::NoError || result->IsEmpty())
        return nullptr;
    return result;
}
} // namespace IndoorGMLValidityNative

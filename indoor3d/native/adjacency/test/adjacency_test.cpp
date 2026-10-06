#include "adjacency_checker.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <set>
#include <utility>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

void require(bool condition, const char* message)
{
    if (!condition)
    {
        std::cerr << message << std::endl;
        std::exit(1);
    }
}

Aabb box(double min_x, double min_y, double min_z, double max_x, double max_y, double max_z)
{
    return Aabb{Vec3{min_x, min_y, min_z}, Vec3{max_x, max_y, max_z}};
}

Triangle triangle(Vec3 a, Vec3 b, Vec3 c)
{
    return Triangle{{a, b, c}};
}

FaceData shared_x_face(double x, double normal_x)
{
    const Vec3 p0{x, 0.0, 0.0};
    const Vec3 p1{x, 1.0, 0.0};
    const Vec3 p2{x, 1.0, 1.0};
    const Vec3 p3{x, 0.0, 1.0};

    FaceData face;
    face.normal = Vec3{normal_x, 0.0, 0.0};
    face.outer_points = {p0, p1, p2, p3};
    face.triangles = {
        triangle(p0, p1, p2),
        triangle(p0, p2, p3)
    };
    return face;
}

void test_z_sweep_matches_bruteforce()
{
    std::vector<CellData> cells(5);
    cells[0].index = 0;
    cells[0].bounds = box(0, 0, 0, 2, 2, 2);
    cells[1].index = 1;
    cells[1].bounds = box(1, 1, 1, 3, 3, 3);
    cells[2].index = 2;
    cells[2].bounds = box(10, 10, 0, 11, 11, 2);
    cells[3].index = 3;
    cells[3].bounds = box(0, 0, 5, 2, 2, 6);
    cells[4].index = 4;
    cells[4].bounds = box(2, 0, 0, 4, 2, 2);

    const double tolerance = 0.001;
    std::set<std::pair<std::size_t, std::size_t>> brute;
    for (std::size_t first = 0; first < cells.size(); ++first)
    {
        for (std::size_t second = first + 1; second < cells.size(); ++second)
        {
            if (bounds_overlap(cells[first].bounds, cells[second].bounds, tolerance))
            {
                brute.emplace(first, second);
            }
        }
    }

    const std::vector<PairIndex> sweep = z_sweep_candidates(cells, tolerance);
    std::set<std::pair<std::size_t, std::size_t>> swept;
    for (const PairIndex& pair : sweep)
    {
        swept.emplace(pair.first, pair.second);
    }
    require(brute == swept, "Z sweep candidate set differs from brute-force AABB set");
}

void test_shared_face_analysis()
{
    CellData first;
    first.index = 0;
    first.bounds = box(0, 0, 0, 1, 1, 1);
    first.faces.push_back(shared_x_face(1.0, 1.0));

    CellData second;
    second.index = 1;
    second.bounds = box(1, 0, 0, 2, 1, 1);
    second.faces.push_back(shared_x_face(1.0, -1.0));

    const std::optional<PairResult> result = analyze_pair(first, second, 0.001, 0.000001);
    require(result.has_value(), "shared coplanar face was not classified adjacent");
    require(result->axis == 0, "shared X face did not produce X adjacency axis");
    require(result->candidates.size() == 1, "shared face should produce one waypoint candidate");

    const CandidateResult& candidate = result->candidates.front();
    require(std::abs(candidate.area - 1.0) <= 1.0e-9, "shared face area differs from expected");
    require(std::abs(candidate.centroid_x - 0.5) <= 1.0e-9, "shared face centroid first coordinate differs");
    require(std::abs(candidate.centroid_y - 0.5) <= 1.0e-9, "shared face centroid second coordinate differs");
}
} // namespace

int main()
{
    test_z_sweep_matches_bruteforce();
    test_shared_face_analysis();
    return 0;
}

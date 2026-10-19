#include "adjacency_data.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>

namespace
{
using namespace IndoorGMLAdjacencyNative;

constexpr std::uint8_t INPUT_MAGIC[8] = {'I', 'G', 'M', 'L', 'A', 'D', 'J', '\0'};
constexpr std::uint8_t OUTPUT_MAGIC[8] = {'I', 'G', 'M', 'L', 'R', 'E', 'S', '\0'};
constexpr std::uint8_t STATE_OUTPUT_MAGIC[8] = {'I', 'G', 'M', 'L', 'S', 'T', 'A', '\0'};
constexpr std::uint64_t INPUT_VERSION_V1 = 1;
constexpr std::uint64_t INPUT_VERSION_V2 = 2;
constexpr std::uint64_t INPUT_VERSION_V3 = 3;
constexpr std::uint64_t INPUT_VERSION_V4 = 4;
constexpr std::uint64_t INPUT_VERSION_V5 = 5;
constexpr std::uint64_t RESULT_VERSION = 1;
constexpr std::uint64_t STATE_RESULT_VERSION = 12;
constexpr std::size_t INPUT_HEADER_SIZE = 32;
constexpr std::size_t CELL_FIXED_SIZE_V1 = 80;
constexpr std::size_t CELL_FIXED_SIZE_V2 = 96;
constexpr std::size_t CELL_FIXED_SIZE_V3 = 104;
constexpr std::size_t FACE_FIXED_SIZE = 56;
constexpr std::size_t FACE_FIXED_SIZE_V5 = 64;
constexpr std::size_t PAIR_FIXED_SIZE = 40;
constexpr std::size_t CANDIDATE_SIZE = 56;

class Reader
{
public:
    Reader(const std::uint8_t* data, std::size_t size) : data_(data), size_(size) {}

    const std::uint8_t* read_bytes(std::size_t length)
    {
        require(length);
        const std::uint8_t* result = data_ + position_;
        position_ += length;
        return result;
    }

    std::uint64_t read_u64()
    {
        const std::uint8_t* bytes = read_bytes(8);
        std::uint64_t value = 0;
        for (unsigned int index = 0; index < 8; ++index)
        {
            value |= static_cast<std::uint64_t>(bytes[index]) << (index * 8);
        }
        return value;
    }

    double read_double()
    {
        const std::uint64_t bits = read_u64();
        double value = 0.0;
        std::memcpy(&value, &bits, sizeof(value));
        return value;
    }

    void skip(std::size_t length) { read_bytes(length); }
    const std::uint8_t* current() const { return data_ + position_; }
    std::size_t remaining() const { return size_ - position_; }
    bool finished() const { return position_ == size_; }

private:
    void require(std::size_t length) const
    {
        if (length > remaining())
        {
            throw std::invalid_argument("adjacency binary payload is truncated");
        }
    }

    const std::uint8_t* data_ = nullptr;
    std::size_t size_ = 0;
    std::size_t position_ = 0;
};

class Writer
{
public:
    void append_bytes(const std::uint8_t* data, std::size_t size)
    {
        bytes_.insert(bytes_.end(), data, data + size);
    }

    void append_u64(std::uint64_t value)
    {
        for (unsigned int index = 0; index < 8; ++index)
        {
            bytes_.push_back(static_cast<std::uint8_t>((value >> (index * 8)) & 0xffu));
        }
    }

    void append_double(double value)
    {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value), "double must be 64-bit");
        std::memcpy(&bits, &value, sizeof(value));
        append_u64(bits);
    }

    std::vector<std::uint8_t> take() { return std::move(bytes_); }

private:
    std::vector<std::uint8_t> bytes_;
};

std::size_t checked_size(std::uint64_t value, const char* label)
{
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max()))
    {
        throw std::invalid_argument(std::string(label) + " is too large");
    }
    return static_cast<std::size_t>(value);
}

std::uint64_t checked_u64(std::size_t value, const char* label)
{
    return static_cast<std::uint64_t>(value);
}

void require_finite(double value, const char* label)
{
    if (!std::isfinite(value))
    {
        throw std::invalid_argument(std::string(label) + " is not finite");
    }
}

Vec3 read_vec3(Reader& reader, const char* label)
{
    Vec3 value{reader.read_double(), reader.read_double(), reader.read_double()};
    require_finite(value.x, label);
    require_finite(value.y, label);
    require_finite(value.z, label);
    return value;
}

FaceData parse_face(const std::uint8_t* data, std::size_t size, std::uint64_t version)
{
    Reader reader(data, size);
    const std::size_t record_size = checked_size(reader.read_u64(), "face record size");
    const std::size_t minimum_size =
        version >= INPUT_VERSION_V5 ? FACE_FIXED_SIZE_V5 : FACE_FIXED_SIZE;
    if (record_size != size || record_size < minimum_size)
    {
        throw std::invalid_argument("face record size is invalid");
    }

    const std::size_t outer_count = checked_size(reader.read_u64(), "outer point count");
    const std::size_t triangle_count = checked_size(reader.read_u64(), "triangle count");
    const std::uint64_t extra = reader.read_u64();
    const std::size_t inner_count = version >= INPUT_VERSION_V4 ?
        checked_size(extra, "inner loop count") : 0;
    if (version < INPUT_VERSION_V4 && extra != 0)
        throw std::invalid_argument("face reserved field is non-zero");
    if (outer_count < 3)
    {
        throw std::invalid_argument("face must contain at least three outer points");
    }

    FaceData face;
    if (version >= INPUT_VERSION_V5)
    {
        const Vec3 coefficients=read_vec3(reader, "face plane normal");
        const double d=reader.read_double();
        require_finite(d, "face plane D");
        const double squared=coefficients.x*coefficients.x+
            coefficients.y*coefficients.y+coefficients.z*coefficients.z;
        if (!std::isfinite(squared) || squared<=1.0e-24)
            throw std::invalid_argument("face plane normal is invalid");
        const double scale=1.0/std::sqrt(squared);
        face.normal={coefficients.x*scale,coefficients.y*scale,coefficients.z*scale};
        face.plane={face.normal,d*scale};
        face.has_plane=true;
    }
    else
    {
        face.normal = read_vec3(reader, "face normal");
    }

    if (outer_count > reader.remaining() / 24)
    {
        throw std::invalid_argument("outer point count exceeds face record");
    }
    face.outer_points.reserve(outer_count);
    for (std::size_t index = 0; index < outer_count; ++index)
    {
        face.outer_points.push_back(read_vec3(reader, "outer point"));
    }

    if (inner_count > reader.remaining() / 8)
        throw std::invalid_argument("inner loop count exceeds face record");
    face.inner_loops.reserve(inner_count);
    for (std::size_t i=0; i<inner_count; ++i)
    {
        const std::size_t count=checked_size(reader.read_u64(), "inner vertex count");
        if (count < 3 || count > reader.remaining()/24)
            throw std::invalid_argument("invalid inner loop vertex count");
        std::vector<Vec3> loop;
        loop.reserve(count);
        for (std::size_t j=0; j<count; ++j)
            loop.push_back(read_vec3(reader, "inner loop point"));
        face.inner_loops.push_back(std::move(loop));
    }

    if (triangle_count > reader.remaining() / 72)
    {
        throw std::invalid_argument("triangle count exceeds face record");
    }
    face.triangles.reserve(triangle_count);
    for (std::size_t index = 0; index < triangle_count; ++index)
    {
        Triangle triangle;
        for (Vec3& point : triangle.points)
        {
            point = read_vec3(reader, "triangle point");
        }
        face.triangles.push_back(triangle);
    }

    if (!reader.finished())
    {
        throw std::invalid_argument("face record has trailing bytes");
    }
    return face;
}

CellData parse_cell(
    const std::uint8_t* data,
    std::size_t size,
    std::size_t expected_index,
    std::uint64_t version
)
{
    Reader reader(data, size);
    const std::size_t fixed_size =
        version == INPUT_VERSION_V1 ? CELL_FIXED_SIZE_V1 :
        (version == INPUT_VERSION_V2 ? CELL_FIXED_SIZE_V2 : CELL_FIXED_SIZE_V3);
    const std::size_t record_size = checked_size(reader.read_u64(), "cell record size");
    if (record_size != size || record_size < fixed_size)
    {
        throw std::invalid_argument("cell record size is invalid");
    }

    const std::size_t cell_index = checked_size(reader.read_u64(), "cell index");
    std::uint64_t flags = CELL_FLAG_ADJACENCY_TARGET;
    std::size_t face_count = 0;
    if (version == INPUT_VERSION_V1)
    {
        face_count = checked_size(reader.read_u64(), "face count");
        if (reader.read_u64() != 0)
        {
            throw std::invalid_argument("cell reserved field is non-zero");
        }
    }
    else
    {
        flags = reader.read_u64();
        face_count = checked_size(reader.read_u64(), "face count");
        if (reader.read_u64() != 0)
        {
            throw std::invalid_argument("cell reserved field is non-zero");
        }
        const std::uint64_t known_flags =
            CELL_FLAG_NEEDS_STATE |
            CELL_FLAG_ADJACENCY_TARGET |
            CELL_FLAG_HAS_FIXED_Z |
            CELL_FLAG_ADJACENCY_DIRTY;
        if ((flags & ~known_flags) != 0)
        {
            throw std::invalid_argument("cell flags contain unsupported bits");
        }
        if ((flags & CELL_FLAG_ADJACENCY_DIRTY) != 0 &&
            (flags & CELL_FLAG_ADJACENCY_TARGET) == 0)
        {
            throw std::invalid_argument("dirty adjacency cell must also be an adjacency target");
        }
    }

    if (cell_index != expected_index)
    {
        throw std::invalid_argument("cell indices must be contiguous and ordered");
    }

    CellData cell;
    cell.index = cell_index;
    cell.flags = flags;
    cell.bounds.minimum = read_vec3(reader, "cell bounds minimum");
    cell.bounds.maximum = read_vec3(reader, "cell bounds maximum");
    if (cell.bounds.minimum.x > cell.bounds.maximum.x ||
        cell.bounds.minimum.y > cell.bounds.maximum.y ||
        cell.bounds.minimum.z > cell.bounds.maximum.z)
    {
        throw std::invalid_argument("cell bounds are inverted");
    }

    if (version >= INPUT_VERSION_V2)
    {
        cell.fixed_z = reader.read_double();
        require_finite(cell.fixed_z, "cell fixed z");
    }

    if (version >= INPUT_VERSION_V3)
    {
        const std::uint64_t raw_category = reader.read_u64();
        if (raw_category > static_cast<std::uint64_t>(CellSpaceCategory::Window))
        {
            throw std::invalid_argument("cell category is invalid");
        }
        cell.category = static_cast<CellSpaceCategory>(raw_category);
    }

    const std::size_t minimum_face_size =
        version >= INPUT_VERSION_V5 ? FACE_FIXED_SIZE_V5 : FACE_FIXED_SIZE;
    if (face_count > reader.remaining() / minimum_face_size)
    {
        throw std::invalid_argument("face count exceeds cell record");
    }
    cell.faces.reserve(face_count);
    for (std::size_t index = 0; index < face_count; ++index)
    {
        if (reader.remaining() < 8)
        {
            throw std::invalid_argument("face record is missing");
        }
        Reader size_reader(reader.current(), reader.remaining());
        const std::size_t face_size = checked_size(size_reader.read_u64(), "face record size");
        if (face_size < minimum_face_size || face_size > reader.remaining())
        {
            throw std::invalid_argument("face record boundary is invalid");
        }
        cell.faces.push_back(parse_face(reader.current(), face_size, version));
        reader.skip(face_size);
    }

    if (!reader.finished())
    {
        throw std::invalid_argument("cell record has trailing bytes");
    }
    return cell;
}

std::uint64_t axis_value(int axis)
{
    if (axis < 0 || axis > 2)
    {
        throw std::invalid_argument("result axis is invalid");
    }
    return static_cast<std::uint64_t>(axis);
}
} // namespace

namespace IndoorGMLAdjacencyNative
{
std::vector<CellData> parse_input_batch(const std::uint8_t* data, std::size_t size)
{
    if (!data && size != 0)
    {
        throw std::invalid_argument("adjacency input pointer is null");
    }
    if (size < INPUT_HEADER_SIZE)
    {
        throw std::invalid_argument("adjacency input header is truncated");
    }

    Reader reader(data, size);
    const std::uint8_t* magic = reader.read_bytes(8);
    if (std::memcmp(magic, INPUT_MAGIC, sizeof(INPUT_MAGIC)) != 0)
    {
        throw std::invalid_argument("adjacency input magic mismatch");
    }
    const std::uint64_t version = reader.read_u64();
    if (version != INPUT_VERSION_V1 &&
        version != INPUT_VERSION_V2 &&
        version != INPUT_VERSION_V3 &&
        version != INPUT_VERSION_V4 &&
        version != INPUT_VERSION_V5)
    {
        throw std::invalid_argument("unsupported adjacency input version");
    }
    const std::size_t cell_count = checked_size(reader.read_u64(), "cell count");
    if (reader.read_u64() != 0)
    {
        throw std::invalid_argument("adjacency input reserved field is non-zero");
    }

    const std::size_t minimum_cell_size =
        version == INPUT_VERSION_V1 ? CELL_FIXED_SIZE_V1 :
        (version == INPUT_VERSION_V2 ? CELL_FIXED_SIZE_V2 : CELL_FIXED_SIZE_V3);
    if (cell_count > reader.remaining() / minimum_cell_size)
    {
        throw std::invalid_argument("cell count exceeds adjacency input");
    }

    std::vector<CellData> cells;
    cells.reserve(cell_count);
    for (std::size_t index = 0; index < cell_count; ++index)
    {
        if (reader.remaining() < 8)
        {
            throw std::invalid_argument("cell record is missing");
        }
        Reader size_reader(reader.current(), reader.remaining());
        const std::size_t cell_size = checked_size(size_reader.read_u64(), "cell record size");
        if (cell_size < minimum_cell_size || cell_size > reader.remaining())
        {
            throw std::invalid_argument("cell record boundary is invalid");
        }
        cells.push_back(parse_cell(reader.current(), cell_size, index, version));
        reader.skip(cell_size);
    }

    if (!reader.finished())
    {
        throw std::invalid_argument("adjacency input has trailing bytes");
    }
    return cells;
}

std::vector<std::uint8_t> serialize_result_batch(std::vector<PairResult> results)
{
    std::sort(results.begin(), results.end(), [](const PairResult& first, const PairResult& second) {
        return std::tie(first.cell1_index, first.cell2_index) <
               std::tie(second.cell1_index, second.cell2_index);
    });

    std::size_t candidate_total = 0;
    for (PairResult& pair : results)
    {
        if (pair.cell1_index >= pair.cell2_index)
        {
            throw std::invalid_argument("result pair indices are not normalized");
        }
        std::sort(pair.candidates.begin(), pair.candidates.end(), [](const CandidateResult& first, const CandidateResult& second) {
            return std::tie(first.face1_index, first.face2_index) <
                   std::tie(second.face1_index, second.face2_index);
        });
        if (pair.candidates.size() > std::numeric_limits<std::size_t>::max() - candidate_total)
        {
            throw std::overflow_error("candidate total overflow");
        }
        candidate_total += pair.candidates.size();
    }

    Writer writer;
    writer.append_bytes(OUTPUT_MAGIC, sizeof(OUTPUT_MAGIC));
    writer.append_u64(RESULT_VERSION);
    writer.append_u64(checked_u64(results.size(), "pair count"));
    writer.append_u64(checked_u64(candidate_total, "candidate total"));

    for (const PairResult& pair : results)
    {
        if (pair.candidates.size() >
            (std::numeric_limits<std::size_t>::max() - PAIR_FIXED_SIZE) / CANDIDATE_SIZE)
        {
            throw std::overflow_error("pair record size overflow");
        }
        const std::size_t record_size = PAIR_FIXED_SIZE + pair.candidates.size() * CANDIDATE_SIZE;
        writer.append_u64(checked_u64(record_size, "pair record size"));
        writer.append_u64(checked_u64(pair.cell1_index, "cell1 index"));
        writer.append_u64(checked_u64(pair.cell2_index, "cell2 index"));
        writer.append_u64(axis_value(pair.axis));
        writer.append_u64(checked_u64(pair.candidates.size(), "candidate count"));

        for (const CandidateResult& candidate : pair.candidates)
        {
            require_finite(candidate.area, "candidate area");
            require_finite(candidate.centroid_x, "candidate centroid x");
            require_finite(candidate.centroid_y, "candidate centroid y");
            if (!(candidate.area > 0.0))
            {
                throw std::invalid_argument("candidate area must be positive");
            }
            writer.append_u64(checked_u64(candidate.face1_index, "face1 index"));
            writer.append_u64(checked_u64(candidate.face2_index, "face2 index"));
            writer.append_u64(axis_value(candidate.axis));
            writer.append_u64(0);
            writer.append_double(candidate.area);
            writer.append_double(candidate.centroid_x);
            writer.append_double(candidate.centroid_y);
        }
    }

    return writer.take();
}

std::vector<std::uint8_t> serialize_state_result_batch(std::vector<StatePointResult> results)
{
    std::sort(results.begin(), results.end(), [](const StatePointResult& first, const StatePointResult& second) {
        return first.cell_index < second.cell_index;
    });
    for (std::size_t index = 1; index < results.size(); ++index)
    {
        if (results[index - 1].cell_index == results[index].cell_index)
        {
            throw std::invalid_argument("duplicate state result cell index");
        }
    }

    Writer writer;
    writer.append_bytes(STATE_OUTPUT_MAGIC, sizeof(STATE_OUTPUT_MAGIC));
    writer.append_u64(STATE_RESULT_VERSION);
    writer.append_u64(checked_u64(results.size(), "state result count"));
    writer.append_u64(0);

    for (const StatePointResult& result : results)
    {
        // V12 per-cell envelope: index, integer ExitCode, State flag,
        // optional State, graph flag, nine aggregate diagnostics and Graph.
        // Room/Stair graph success intentionally has no State until the
        // completed OPTIMIZED graph performs final selection.
        // A native execution exception is deliberately NOT an ExitCode.
        const bool success = result.exit_code == StateExitCode::Success;
        if (!success && result.point.has_value())
            throw std::invalid_argument("failed result must have no State");
        if (!success && (!result.reference_points.empty() ||
                         !result.graph_node_points.empty() ||
                         !result.graph_edge_indices.empty() ||
                         !result.graph_loop_candidates.empty() ||
                         !result.graph_floor_partitions.empty()))
            throw std::invalid_argument("failed result must have no Graph data");
        writer.append_u64(checked_u64(result.cell_index, "state cell index"));
        writer.append_u64(static_cast<std::uint64_t>(result.exit_code));
        writer.append_u64(result.point.has_value() ? 1 : 0);
        if (result.point)
        {
            require_finite(result.point->x, "state point x");
            require_finite(result.point->y, "state point y");
            require_finite(result.point->z, "state point z");
            writer.append_double(result.point->x);
            writer.append_double(result.point->y);
            writer.append_double(result.point->z);
        }
        const bool has_graph = success &&
            (!result.graph_node_points.empty() || !result.reference_points.empty() ||
             !result.graph_floor_partitions.empty());
        writer.append_u64(has_graph ? 1 : 0);
        const StateDiagnostics& diag = result.diagnostics;
        writer.append_u64(diag.floor_faces);
        writer.append_u64(diag.prepared_faces);
        writer.append_u64(diag.completed_polygons);
        writer.append_u64(diag.failed_polygons);
        writer.append_u64(diag.reference_candidates);
        writer.append_u64(diag.rejected_centroids);
        writer.append_u64(diag.rejected_outside);
        writer.append_u64(diag.rejected_clearance);
        writer.append_u64(diag.accepted_references);
        if (!has_graph) continue; // V12: graph=nil is a valid result.
        if (result.reference_points.size() != result.reference_kinds.size())
            throw std::invalid_argument("reference point/kind count mismatch");
        writer.append_u64(checked_u64(result.reference_points.size(), "reference point count"));
        for (std::size_t i = 0; i < result.reference_points.size(); ++i)
        {
            const Vec3& point = result.reference_points[i];
            const std::uint64_t kind = result.reference_kinds[i];
            if (kind < 1 || kind > 4)
                throw std::invalid_argument("reference point kind is invalid");
            require_finite(point.x, "reference point x");
            require_finite(point.y, "reference point y");
            require_finite(point.z, "reference point z");
            writer.append_double(point.x);
            writer.append_double(point.y);
            writer.append_double(point.z);
            writer.append_u64(kind);
        }

        if (result.graph_node_points.size() != result.graph_node_radii.size())
            throw std::invalid_argument("debug graph node/radius count mismatch");
        writer.append_u64(checked_u64(result.graph_node_points.size(), "debug graph node count"));
        for (std::size_t i = 0; i < result.graph_node_points.size(); ++i)
        {
            const Vec3& point = result.graph_node_points[i];
            const double radius = result.graph_node_radii[i];
            require_finite(point.x, "debug graph node x");
            require_finite(point.y, "debug graph node y");
            require_finite(point.z, "debug graph node z");
            require_finite(radius, "debug graph node radius");
            if (radius < 0.0)
                throw std::invalid_argument("negative debug graph node radius");
            writer.append_double(point.x);
            writer.append_double(point.y);
            writer.append_double(point.z);
            writer.append_double(radius);
        }
        if (result.graph_edge_indices.size() % 2 != 0)
            throw std::invalid_argument("debug graph edge indices must be paired");
        writer.append_u64(checked_u64(result.graph_edge_indices.size() / 2, "debug graph edge count"));
        for (std::size_t i = 0; i < result.graph_edge_indices.size(); i += 2)
        {
            const std::uint64_t first = result.graph_edge_indices[i];
            const std::uint64_t second = result.graph_edge_indices[i + 1];
            if (first >= second || second >= result.graph_node_points.size())
                throw std::invalid_argument("invalid debug graph edge indices");
            writer.append_u64(first);
            writer.append_u64(second);
        }

        // V7: each geometry-validated simple loop has a VARIABLE number
        // of ordered vertices (3+), preserving the older V6 body fields.
        writer.append_u64(checked_u64(result.graph_loop_candidates.size(), "loop candidate count"));
        for (const StatePointResult::LoopCandidate& candidate : result.graph_loop_candidates)
        {
            if (candidate.vertices.size() < 3 || candidate.vertices.size() > 32)
                throw std::invalid_argument("invalid loop vertex count");
            writer.append_u64(checked_u64(candidate.vertices.size(), "loop vertex count"));
            for (std::uint64_t index : candidate.vertices)
            {
                if (index >= result.graph_node_points.size())
                    throw std::invalid_argument("loop vertex index outside graph");
                writer.append_u64(index);
            }
            require_finite(candidate.representative.x, "loop point x");
            require_finite(candidate.representative.y, "loop point y");
            require_finite(candidate.representative.z, "loop point z");
            require_finite(candidate.radius, "loop radius");
            if (candidate.radius < 0.0)
                throw std::invalid_argument("loop radius negative");
            writer.append_double(candidate.representative.x);
            writer.append_double(candidate.representative.y);
            writer.append_double(candidate.representative.z);
            writer.append_double(candidate.radius);
            writer.append_u64(checked_u64(candidate.visible_neighbors.size(), "loop visible count"));
            for (const std::uint64_t index : candidate.visible_neighbors)
            {
                if (index >= result.graph_node_points.size())
                    throw std::invalid_argument("loop visible index outside graph");
                writer.append_u64(index);
            }
        }

        writer.append_u64(checked_u64(
            result.graph_floor_partitions.size(), "floor partition count"));
        for (const StatePointResult::FloorPartition& partition :
             result.graph_floor_partitions)
        {
            if (partition.outer.size() < 3)
                throw std::invalid_argument("floor partition outer ring is invalid");
            writer.append_u64(checked_u64(
                partition.outer.size(), "floor partition outer point count"));
            for (const Vec3& point : partition.outer)
            {
                require_finite(point.x, "floor partition x");
                require_finite(point.y, "floor partition y");
                require_finite(point.z, "floor partition z");
                writer.append_double(point.x);
                writer.append_double(point.y);
                writer.append_double(point.z);
            }
            writer.append_u64(checked_u64(
                partition.holes.size(), "floor partition hole count"));
            for (const std::vector<Vec3>& hole : partition.holes)
            {
                if (hole.size() < 3)
                    throw std::invalid_argument("floor partition hole ring is invalid");
                writer.append_u64(checked_u64(
                    hole.size(), "floor partition hole point count"));
                for (const Vec3& point : hole)
                {
                    require_finite(point.x, "floor partition hole x");
                    require_finite(point.y, "floor partition hole y");
                    require_finite(point.z, "floor partition hole z");
                    writer.append_double(point.x);
                    writer.append_double(point.y);
                    writer.append_double(point.z);
                }
            }
        }
    }
    return writer.take();
}
} // namespace IndoorGMLAdjacencyNative

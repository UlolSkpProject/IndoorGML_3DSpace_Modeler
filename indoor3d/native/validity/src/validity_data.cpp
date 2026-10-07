#include "validity_data.h"

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
using namespace IndoorGMLValidityNative;

constexpr std::uint8_t GEOMETRY_MAGIC[8] = {'I','G','M','L','A','D','J','\0'};
constexpr std::uint8_t REQUEST_MAGIC[8] = {'I','G','M','L','V','L','D','\0'};
constexpr std::uint8_t RESULT_MAGIC[8] = {'I','G','M','L','V','R','S','\0'};
constexpr std::uint64_t GEOMETRY_VERSION = 2;
constexpr std::uint64_t VALIDITY_VERSION = 1;
constexpr std::size_t HEADER_SIZE = 32;
constexpr std::size_t CELL_FIXED_SIZE = 96;
constexpr std::size_t FACE_FIXED_SIZE = 56;
constexpr std::size_t RESULT_FIXED_SIZE = 80;

class Reader
{
public:
    Reader(const std::uint8_t* data, std::size_t size) : data_(data), size_(size) {}

    const std::uint8_t* read_bytes(std::size_t length)
    {
        require(length);
        const std::uint8_t* value = data_ + position_;
        position_ += length;
        return value;
    }

    std::uint64_t read_u64()
    {
        const std::uint8_t* bytes = read_bytes(8);
        std::uint64_t value = 0;
        for (unsigned int index=0; index<8; ++index)
            value |= static_cast<std::uint64_t>(bytes[index]) << (index * 8);
        return value;
    }

    double read_double()
    {
        const std::uint64_t bits = read_u64();
        double value = 0.0;
        std::memcpy(&value, &bits, sizeof(value));
        return value;
    }

    void skip(std::size_t length) { (void)read_bytes(length); }
    const std::uint8_t* current() const { return data_ + position_; }
    std::size_t remaining() const { return size_ - position_; }
    bool finished() const { return position_ == size_; }

private:
    void require(std::size_t length) const
    {
        if (length > remaining()) throw std::invalid_argument("validity payload is truncated");
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
        for (unsigned int index=0; index<8; ++index)
            bytes_.push_back(static_cast<std::uint8_t>((value >> (index * 8)) & 0xffu));
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
        throw std::invalid_argument(std::string(label) + " is too large");
    return static_cast<std::size_t>(value);
}

void require_finite(double value, const char* label)
{
    if (!std::isfinite(value)) throw std::invalid_argument(std::string(label) + " is not finite");
}

Vec3 read_vec3(Reader& reader, const char* label)
{
    Vec3 value{reader.read_double(), reader.read_double(), reader.read_double()};
    require_finite(value.x, label);
    require_finite(value.y, label);
    require_finite(value.z, label);
    return value;
}

FaceData parse_face(const std::uint8_t* data, std::size_t size)
{
    Reader reader(data, size);
    const std::size_t record_size = checked_size(reader.read_u64(), "face record size");
    if (record_size != size || record_size < FACE_FIXED_SIZE)
        throw std::invalid_argument("validity face record size is invalid");

    const std::size_t outer_count = checked_size(reader.read_u64(), "outer point count");
    const std::size_t triangle_count = checked_size(reader.read_u64(), "triangle count");
    if (reader.read_u64() != 0) throw std::invalid_argument("validity face reserved field is non-zero");
    if (outer_count < 3) throw std::invalid_argument("validity face requires at least three outer points");

    FaceData face;
    face.normal = read_vec3(reader, "face normal");
    if (outer_count > reader.remaining() / 24)
        throw std::invalid_argument("validity outer point count exceeds record");
    face.outer_points.reserve(outer_count);
    for (std::size_t index=0; index<outer_count; ++index)
        face.outer_points.push_back(read_vec3(reader, "outer point"));

    if (triangle_count > reader.remaining() / 72)
        throw std::invalid_argument("validity triangle count exceeds record");
    face.triangles.reserve(triangle_count);
    for (std::size_t index=0; index<triangle_count; ++index)
    {
        Triangle triangle;
        for (Vec3& point : triangle.points) point = read_vec3(reader, "triangle point");
        face.triangles.push_back(triangle);
    }
    if (!reader.finished()) throw std::invalid_argument("validity face record has trailing bytes");
    return face;
}

CellData parse_cell(const std::uint8_t* data, std::size_t size, std::size_t expected_index)
{
    Reader reader(data, size);
    const std::size_t record_size = checked_size(reader.read_u64(), "cell record size");
    if (record_size != size || record_size < CELL_FIXED_SIZE)
        throw std::invalid_argument("validity cell record size is invalid");

    const std::size_t cell_index = checked_size(reader.read_u64(), "cell index");
    if (cell_index != expected_index)
        throw std::invalid_argument("validity cell indices must be contiguous and ordered");

    const std::uint64_t flags = reader.read_u64();
    const std::size_t face_count = checked_size(reader.read_u64(), "face count");
    if (reader.read_u64() != 0) throw std::invalid_argument("validity cell reserved field is non-zero");

    const std::uint64_t known_flags =
        CELL_FLAG_NEEDS_STATE | CELL_FLAG_ADJACENCY_TARGET |
        CELL_FLAG_HAS_FIXED_Z | CELL_FLAG_ADJACENCY_DIRTY;
    if ((flags & ~known_flags) != 0)
        throw std::invalid_argument("validity cell flags contain unsupported bits");

    CellData cell;
    cell.index = cell_index;
    cell.flags = flags;
    cell.bounds.minimum = read_vec3(reader, "cell bounds minimum");
    cell.bounds.maximum = read_vec3(reader, "cell bounds maximum");
    if (cell.bounds.minimum.x > cell.bounds.maximum.x ||
        cell.bounds.minimum.y > cell.bounds.maximum.y ||
        cell.bounds.minimum.z > cell.bounds.maximum.z)
        throw std::invalid_argument("validity cell bounds are inverted");

    cell.fixed_z = reader.read_double();
    require_finite(cell.fixed_z, "cell fixed z");

    if (face_count > reader.remaining() / FACE_FIXED_SIZE)
        throw std::invalid_argument("validity face count exceeds cell record");
    cell.faces.reserve(face_count);
    for (std::size_t index=0; index<face_count; ++index)
    {
        if (reader.remaining() < 8) throw std::invalid_argument("validity face record is missing");
        Reader size_reader(reader.current(), reader.remaining());
        const std::size_t face_size = checked_size(size_reader.read_u64(), "face record size");
        if (face_size < FACE_FIXED_SIZE || face_size > reader.remaining())
            throw std::invalid_argument("validity face record boundary is invalid");
        cell.faces.push_back(parse_face(reader.current(), face_size));
        reader.skip(face_size);
    }
    if (!reader.finished()) throw std::invalid_argument("validity cell record has trailing bytes");
    return cell;
}

std::uint64_t encoded_axis(int axis)
{
    return axis >= 0 && axis <= 2 ? static_cast<std::uint64_t>(axis) : 3ull;
}
} // namespace

namespace IndoorGMLValidityNative
{
std::vector<CellData> parse_geometry_batch(const std::uint8_t* data, std::size_t size)
{
    if (!data && size != 0) throw std::invalid_argument("validity geometry pointer is null");
    if (size < HEADER_SIZE) throw std::invalid_argument("validity geometry header is truncated");

    Reader reader(data, size);
    if (std::memcmp(reader.read_bytes(8), GEOMETRY_MAGIC, sizeof(GEOMETRY_MAGIC)) != 0)
        throw std::invalid_argument("validity geometry magic mismatch");
    if (reader.read_u64() != GEOMETRY_VERSION)
        throw std::invalid_argument("validity requires geometry protocol version 2");
    const std::size_t cell_count = checked_size(reader.read_u64(), "cell count");
    if (reader.read_u64() != 0) throw std::invalid_argument("validity geometry reserved field is non-zero");
    if (cell_count > reader.remaining() / CELL_FIXED_SIZE)
        throw std::invalid_argument("validity cell count exceeds geometry payload");

    std::vector<CellData> cells;
    cells.reserve(cell_count);
    for (std::size_t index=0; index<cell_count; ++index)
    {
        if (reader.remaining() < 8) throw std::invalid_argument("validity cell record is missing");
        Reader size_reader(reader.current(), reader.remaining());
        const std::size_t cell_size = checked_size(size_reader.read_u64(), "cell record size");
        if (cell_size < CELL_FIXED_SIZE || cell_size > reader.remaining())
            throw std::invalid_argument("validity cell record boundary is invalid");
        cells.push_back(parse_cell(reader.current(), cell_size, index));
        reader.skip(cell_size);
    }
    if (!reader.finished()) throw std::invalid_argument("validity geometry has trailing bytes");
    return cells;
}

std::vector<ValidityPairRequest> parse_validity_requests(const std::uint8_t* data, std::size_t size)
{
    if (!data && size != 0) throw std::invalid_argument("validity request pointer is null");
    if (size < HEADER_SIZE) throw std::invalid_argument("validity request header is truncated");

    Reader reader(data, size);
    if (std::memcmp(reader.read_bytes(8), REQUEST_MAGIC, sizeof(REQUEST_MAGIC)) != 0)
        throw std::invalid_argument("validity request magic mismatch");
    if (reader.read_u64() != VALIDITY_VERSION)
        throw std::invalid_argument("unsupported validity request version");
    const std::size_t count = checked_size(reader.read_u64(), "validity request count");
    if (reader.read_u64() != 0) throw std::invalid_argument("validity request reserved field is non-zero");
    if (count > reader.remaining() / 24)
        throw std::invalid_argument("validity request count exceeds payload");

    std::vector<ValidityPairRequest> requests;
    requests.reserve(count);
    for (std::size_t index=0; index<count; ++index)
    {
        ValidityPairRequest request;
        request.first = checked_size(reader.read_u64(), "validity first index");
        request.second = checked_size(reader.read_u64(), "validity second index");
        const std::uint64_t code = reader.read_u64();
        if (request.first >= request.second)
            throw std::invalid_argument("validity pair indices must be normalized");
        if (code != VALIDITY_CODE_OVERLAP && code != VALIDITY_CODE_ADJACENCY)
            throw std::invalid_argument("unsupported validity code");
        request.code = static_cast<std::uint32_t>(code);
        requests.push_back(request);
    }
    if (!reader.finished()) throw std::invalid_argument("validity request has trailing bytes");
    return requests;
}

std::vector<std::uint8_t> serialize_validity_results(std::vector<ValidityResult> results)
{
    std::sort(results.begin(), results.end(), [](const ValidityResult& a, const ValidityResult& b) {
        return std::tie(a.code, a.first, a.second) < std::tie(b.code, b.first, b.second);
    });

    Writer writer;
    writer.append_bytes(RESULT_MAGIC, sizeof(RESULT_MAGIC));
    writer.append_u64(VALIDITY_VERSION);
    writer.append_u64(static_cast<std::uint64_t>(results.size()));
    writer.append_u64(0);

    for (const ValidityResult& result : results)
    {
        const std::size_t record_size =
            RESULT_FIXED_SIZE + result.vertices.size() * 24 + result.triangles.size() * 24;
        writer.append_u64(static_cast<std::uint64_t>(record_size));
        writer.append_u64(static_cast<std::uint64_t>(result.first));
        writer.append_u64(static_cast<std::uint64_t>(result.second));
        writer.append_u64(static_cast<std::uint64_t>(result.code));
        writer.append_u64(static_cast<std::uint64_t>(result.status));
        writer.append_u64(encoded_axis(result.axis));
        writer.append_double(result.volume);
        writer.append_u64(static_cast<std::uint64_t>(result.component_count));
        writer.append_u64(static_cast<std::uint64_t>(result.vertices.size()));
        writer.append_u64(static_cast<std::uint64_t>(result.triangles.size()));
        for (const Vec3& point : result.vertices)
        {
            writer.append_double(point.x);
            writer.append_double(point.y);
            writer.append_double(point.z);
        }
        for (const auto& triangle : result.triangles)
        {
            writer.append_u64(triangle[0]);
            writer.append_u64(triangle[1]);
            writer.append_u64(triangle[2]);
        }
    }
    return writer.take();
}
} // namespace IndoorGMLValidityNative

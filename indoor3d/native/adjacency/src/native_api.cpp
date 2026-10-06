#include "native_api.h"

#include "adjacency_session.h"

#include <climits>
#include <cstdint>
#include <exception>
#include <vector>

namespace
{
using namespace IndoorGMLAdjacencyNative;

AdjacencySession& session()
{
    static AdjacencySession value;
    return value;
}

template <typename Function>
VALUE protect_native_call(Function&& function)
{
    try
    {
        return function();
    }
    catch (const std::exception& error)
    {
        rb_raise(rb_eRuntimeError, "%s", error.what());
    }
    catch (...)
    {
        rb_raise(rb_eRuntimeError, "unknown IndoorGML adjacency native error");
    }
    return Qnil;
}

void hash_set(VALUE hash, const char* key, VALUE value)
{
    rb_hash_aset(hash, ID2SYM(rb_intern(key)), value);
}
} // namespace

VALUE adjacency_native_load_batch(VALUE self, VALUE buffer)
{
    (void)self;
    Check_Type(buffer, T_STRING);
    const auto* data = reinterpret_cast<const std::uint8_t*>(RSTRING_PTR(buffer));
    const std::size_t size = static_cast<std::size_t>(RSTRING_LEN(buffer));
    return protect_native_call([data, size]() {
        return ULL2NUM(static_cast<unsigned long long>(session().load_batch(data, size)));
    });
}

VALUE adjacency_native_start_check(VALUE self, VALUE length_tolerance, VALUE normal_tolerance)
{
    (void)self;
    const double length = NUM2DBL(length_tolerance);
    const double normal = NUM2DBL(normal_tolerance);
    return protect_native_call([length, normal]() {
        return ULL2NUM(static_cast<unsigned long long>(session().start_check(length, normal)));
    });
}

VALUE adjacency_native_get_progress(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const ProgressSnapshot progress = session().get_progress();
        VALUE result = rb_hash_new();
        hash_set(result, "current", ULL2NUM(static_cast<unsigned long long>(progress.current)));
        hash_set(result, "total", ULL2NUM(static_cast<unsigned long long>(progress.total)));
        hash_set(result, "candidate_count", ULL2NUM(static_cast<unsigned long long>(progress.total)));
        hash_set(result, "running", progress.running ? Qtrue : Qfalse);
        hash_set(result, "completed", progress.completed ? Qtrue : Qfalse);
        hash_set(result, "failed", progress.failed ? Qtrue : Qfalse);
        hash_set(
            result,
            "candidate_generation_duration",
            DBL2NUM(progress.candidate_generation_duration)
        );
        return result;
    });
}

VALUE adjacency_native_get_result_bytes(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const std::vector<std::uint8_t> bytes = session().get_result_bytes();
        if (bytes.size() > static_cast<std::size_t>(LONG_MAX))
        {
            rb_raise(rb_eRuntimeError, "native adjacency result is too large for Ruby string");
        }
        if (bytes.empty())
        {
            return rb_str_new("", 0);
        }
        return rb_str_new(
            reinterpret_cast<const char*>(bytes.data()),
            static_cast<long>(bytes.size())
        );
    });
}

VALUE adjacency_native_get_metrics(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const MetricsSnapshot metrics = session().get_metrics();
        VALUE result = rb_hash_new();
        hash_set(result, "candidate_count", ULL2NUM(static_cast<unsigned long long>(metrics.candidate_count)));
        hash_set(result, "adjacent_pair_count", ULL2NUM(static_cast<unsigned long long>(metrics.adjacent_pair_count)));
        hash_set(result, "failed_pair_count", ULL2NUM(static_cast<unsigned long long>(metrics.failed_pair_count)));
        hash_set(
            result,
            "candidate_generation_duration",
            DBL2NUM(metrics.candidate_generation_duration)
        );
        hash_set(result, "narrow_phase_duration", DBL2NUM(metrics.narrow_phase_duration));
        return result;
    });
}

VALUE adjacency_native_clear_session(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        session().clear();
        return Qtrue;
    });
}

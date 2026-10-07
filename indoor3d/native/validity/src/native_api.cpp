#include "native_api.h"

#include "validity_session.h"

#include <climits>
#include <cstdint>
#include <exception>
#include <vector>

namespace
{
using namespace IndoorGMLValidityNative;

ValiditySession& session()
{
    static ValiditySession value;
    return value;
}

template <typename Function>
VALUE protect_native_call(Function&& function)
{
    try { return function(); }
    catch (const std::exception& error) { rb_raise(rb_eRuntimeError,"%s",error.what()); }
    catch (...) { rb_raise(rb_eRuntimeError,"unknown IndoorGML validity native error"); }
    return Qnil;
}

void hash_set(VALUE hash,const char* key,VALUE value)
{
    rb_hash_aset(hash,ID2SYM(rb_intern(key)),value);
}

VALUE bytes_to_string(const std::vector<std::uint8_t>& bytes)
{
    if (bytes.size()>static_cast<std::size_t>(LONG_MAX))
        rb_raise(rb_eRuntimeError,"validity native result is too large for Ruby string");
    if (bytes.empty()) return rb_str_new("",0);
    return rb_str_new(reinterpret_cast<const char*>(bytes.data()),static_cast<long>(bytes.size()));
}
} // namespace

VALUE validity_native_load_batch(VALUE self,VALUE geometry)
{
    (void)self;
    Check_Type(geometry,T_STRING);
    const auto* data=reinterpret_cast<const std::uint8_t*>(RSTRING_PTR(geometry));
    const std::size_t size=static_cast<std::size_t>(RSTRING_LEN(geometry));
    return protect_native_call([data,size]() {
        return ULL2NUM(static_cast<unsigned long long>(session().load_batch(data,size)));
    });
}

VALUE validity_native_start_check(
    VALUE self,
    VALUE requests,
    VALUE overlap_tolerance,
    VALUE normal_tolerance
)
{
    (void)self;
    Check_Type(requests,T_STRING);
    const auto* data=reinterpret_cast<const std::uint8_t*>(RSTRING_PTR(requests));
    const std::size_t size=static_cast<std::size_t>(RSTRING_LEN(requests));
    const double overlap=NUM2DBL(overlap_tolerance);
    const double normal=NUM2DBL(normal_tolerance);
    return protect_native_call([data,size,overlap,normal]() {
        return ULL2NUM(static_cast<unsigned long long>(
            session().start_check(data,size,overlap,normal)
        ));
    });
}

VALUE validity_native_get_progress(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const ProgressSnapshot progress=session().get_progress();
        VALUE result=rb_hash_new();
        hash_set(result,"current",ULL2NUM(static_cast<unsigned long long>(progress.current)));
        hash_set(result,"total",ULL2NUM(static_cast<unsigned long long>(progress.total)));
        hash_set(result,"running",progress.running?Qtrue:Qfalse);
        hash_set(result,"completed",progress.completed?Qtrue:Qfalse);
        return result;
    });
}

VALUE validity_native_get_metrics(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const MetricsSnapshot metrics=session().get_metrics();
        VALUE result=rb_hash_new();
        hash_set(result,"request_count",ULL2NUM(static_cast<unsigned long long>(metrics.request_count)));
        hash_set(result,"overlap_701_count",ULL2NUM(static_cast<unsigned long long>(metrics.overlap_701_count)));
        hash_set(result,"adjacency_704_count",ULL2NUM(static_cast<unsigned long long>(metrics.adjacency_704_count)));
        hash_set(result,"manifold_build_count",ULL2NUM(static_cast<unsigned long long>(metrics.manifold_build_count)));
        hash_set(result,"uncertain_count",ULL2NUM(static_cast<unsigned long long>(metrics.uncertain_count)));
        hash_set(result,"duration",DBL2NUM(metrics.duration));
        return result;
    });
}

VALUE validity_native_get_result_bytes(VALUE self)
{
    (void)self;
    return protect_native_call([]() { return bytes_to_string(session().get_result_bytes()); });
}

VALUE validity_native_clear_session(VALUE self)
{
    (void)self;
    return protect_native_call([]() { session().clear(); return Qtrue; });
}

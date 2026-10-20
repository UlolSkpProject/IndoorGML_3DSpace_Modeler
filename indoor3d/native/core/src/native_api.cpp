#include "native_api.h"

#include "adjacency_session.h"

#include <array>
#include <climits>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>
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
        rb_raise(rb_eRuntimeError, "unknown IndoorGML geometry native error");
    }
    return Qnil;
}

void hash_set(VALUE hash, const char* key, VALUE value)
{
    rb_hash_aset(hash, ID2SYM(rb_intern(key)), value);
}

VALUE bytes_to_ruby_string(const std::vector<std::uint8_t>& bytes)
{
    if (bytes.size() > static_cast<std::size_t>(LONG_MAX))
        rb_raise(rb_eRuntimeError, "native result is too large for Ruby string");
    if (bytes.empty()) return rb_str_new("", 0);
    return rb_str_new(
        reinterpret_cast<const char*>(bytes.data()),
        static_cast<long>(bytes.size())
    );
}

VALUE phase_symbol(ProgressPhase phase)
{
    switch (phase)
    {
    case ProgressPhase::State: return ID2SYM(rb_intern("state"));
    case ProgressPhase::Adjacency: return ID2SYM(rb_intern("adjacency"));
    default: return ID2SYM(rb_intern("none"));
    }
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

VALUE adjacency_native_set_cell_keys(VALUE self, VALUE keys)
{
    (void)self;
    Check_Type(keys,T_ARRAY);
    return protect_native_call([keys]() {
        const long count=RARRAY_LEN(keys);
        std::vector<std::string> values;
        values.reserve(static_cast<std::size_t>(count));
        for(long index=0;index<count;++index)
        {
            VALUE value=rb_ary_entry(keys,index);
            StringValue(value);
            values.emplace_back(RSTRING_PTR(value),static_cast<std::size_t>(RSTRING_LEN(value)));
            if(values.back().empty()) throw std::invalid_argument("CellSpace key is empty");
        }
        session().set_cell_keys(std::move(values));
        return Qtrue;
    });
}

VALUE adjacency_native_start_state_check(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        return ULL2NUM(static_cast<unsigned long long>(session().start_state_check()));
    });
}

VALUE adjacency_native_get_state_result_bytes(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        return bytes_to_ruby_string(session().get_state_result_bytes());
    });
}

VALUE adjacency_native_commit_reference_graph_batch(VALUE self, VALUE transform_bytes)
{
    (void)self;
    Check_Type(transform_bytes,T_STRING);
    const std::size_t size=static_cast<std::size_t>(RSTRING_LEN(transform_bytes));
    if(size%(16*sizeof(double))!=0)
        rb_raise(rb_eArgError,"invalid Reference CellSpace frame payload");
    std::vector<std::array<double,16>> frames(size/(16*sizeof(double)));
    for(std::size_t i=0;i<frames.size();++i)
        std::memcpy(frames[i].data(),
            RSTRING_PTR(transform_bytes)+i*16*sizeof(double),
            16*sizeof(double));
    return protect_native_call([&frames]() {
        session().commit_reference_graph_batch(frames);
        return Qtrue;
    });
}

// Pairs are six little-endian float64 coordinates per segment:
// a.x,a.y,a.z,b.x,b.y,b.z. This avoids per-vertex Ruby array churn.
VALUE adjacency_native_validate_room_los(
    VALUE self, VALUE cell_index, VALUE segment_bytes, VALUE tolerance
)
{
    (void)self;
    Check_Type(segment_bytes, T_STRING);
    const std::uint64_t raw_index = NUM2ULL(cell_index);
    const double epsilon = NUM2DBL(tolerance);
    const std::size_t size = static_cast<std::size_t>(RSTRING_LEN(segment_bytes));
    if (size % (6 * sizeof(double)) != 0 ||
        size > 2048 * 6 * sizeof(double) ||
        raw_index > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max()))
        rb_raise(rb_eArgError, "invalid Room LOS segment payload");

    const auto* data = reinterpret_cast<const std::uint8_t*>(RSTRING_PTR(segment_bytes));
    return protect_native_call([data, size, raw_index, epsilon]() {
        std::vector<std::pair<Vec3, Vec3>> segments;
        segments.reserve(size / (6 * sizeof(double)));
        for (std::size_t offset = 0; offset < size; offset += 6 * sizeof(double))
        {
            double values[6];
            std::memcpy(values, data + offset, sizeof(values));
            for (double value : values)
                if (!std::isfinite(value))
                    throw std::invalid_argument("non-finite Room LOS coordinate");
            segments.push_back({
                {values[0], values[1], values[2]},
                {values[3], values[4], values[5]}
            });
        }

        const std::vector<bool> checked = session().validate_room_los(
            static_cast<std::size_t>(raw_index), segments, epsilon
        );
        VALUE result = rb_ary_new_capa(static_cast<long>(checked.size()));
        for (bool visible : checked)
            rb_ary_push(result, visible ? Qtrue : Qfalse);
        return result;
    });
}

VALUE adjacency_native_get_reference_graph(VALUE self, VALUE cell_key, VALUE stage)
{
    (void)self;
    StringValue(cell_key);
    const std::string key(RSTRING_PTR(cell_key),static_cast<std::size_t>(RSTRING_LEN(cell_key)));
    const ID stage_id=SYM2ID(stage);
    ReferenceGraphStage selected;
    if(stage_id==rb_intern("before")) selected=ReferenceGraphStage::Before;
    else if(stage_id==rb_intern("after")) selected=ReferenceGraphStage::After;
    else if(stage_id==rb_intern("collapsed")) selected=ReferenceGraphStage::Collapsed;
    else if(stage_id==rb_intern("optimized")) selected=ReferenceGraphStage::Optimized;
    else if(stage_id==rb_intern("short_path_graph")) selected=ReferenceGraphStage::ShortPathGraph;
    else rb_raise(rb_eArgError,"unknown Reference Graph stage");
    return protect_native_call([key,selected]() {
        const auto graph=session().get_reference_graph(key,selected);
        if(!graph) return Qnil;
        VALUE result=rb_hash_new();
        VALUE nodes=rb_ary_new_capa(static_cast<long>(graph->nodes.size()));
        for(const auto& node:graph->nodes)
        {
            VALUE point=rb_ary_new_capa(3);
            rb_ary_push(point,DBL2NUM(node.point.x));
            rb_ary_push(point,DBL2NUM(node.point.y));
            rb_ary_push(point,DBL2NUM(node.point.z));
            rb_ary_push(nodes,point);
        }
        VALUE edges=rb_ary_new_capa(static_cast<long>(graph->edges.size()));
        for(const auto& edge:graph->edges)
        {
            VALUE pair=rb_ary_new_capa(2);
            rb_ary_push(pair,ULL2NUM(static_cast<unsigned long long>(edge.first)));
            rb_ary_push(pair,ULL2NUM(static_cast<unsigned long long>(edge.second)));
            rb_ary_push(edges,pair);
        }
        hash_set(result,"nodes",nodes);
        hash_set(result,"edges",edges);
        return result;
    });
}

// Two CellSpace-local waypoint coordinates (six little-endian float64).
// Results stay separate until Ruby transforms each path back to Root-Local.
VALUE adjacency_native_get_reference_transition_curve(
    VALUE self,VALUE first_cell_key,VALUE second_cell_key,VALUE waypoint_bytes
)
{
    (void)self;
    StringValue(first_cell_key);
    StringValue(second_cell_key);
    Check_Type(waypoint_bytes,T_STRING);
    if(RSTRING_LEN(waypoint_bytes)!=static_cast<long>(6*sizeof(double)))
        rb_raise(rb_eArgError,"Reference waypoints require six float64 values");
    const std::string first(RSTRING_PTR(first_cell_key),
                            static_cast<std::size_t>(RSTRING_LEN(first_cell_key)));
    const std::string second(RSTRING_PTR(second_cell_key),
                             static_cast<std::size_t>(RSTRING_LEN(second_cell_key)));
    double values[6];
    std::memcpy(values,RSTRING_PTR(waypoint_bytes),sizeof(values));
    for(const double value:values) if(!std::isfinite(value))
        rb_raise(rb_eArgError,"Reference waypoint coordinate is not finite");
    return protect_native_call([first,second,&values]() {
        const auto paths=session().get_reference_transition_curve(
            first,second,{values[0],values[1],values[2]},
                         {values[3],values[4],values[5]});
        if(paths.first.empty() || paths.second.empty()) return Qnil;
        VALUE result=rb_ary_new_capa(2);
        for(const auto* path:{&paths.first,&paths.second})
        {
            VALUE list=rb_ary_new_capa(static_cast<long>(path->size()));
            for(const auto& item:*path)
            {
                VALUE point=rb_ary_new_capa(3);
                rb_ary_push(point,DBL2NUM(item.x));
                rb_ary_push(point,DBL2NUM(item.y));
                rb_ary_push(point,DBL2NUM(item.z));
                rb_ary_push(list,point);
            }
            rb_ary_push(result,list);
        }
        return result;
    });
}

VALUE adjacency_native_get_reference_waypoint_anchors(
    VALUE self,VALUE first_cell_key,VALUE second_cell_key,VALUE waypoint_bytes
)
{
    (void)self;
    StringValue(first_cell_key);
    StringValue(second_cell_key);
    Check_Type(waypoint_bytes,T_STRING);
    if(RSTRING_LEN(waypoint_bytes)!=static_cast<long>(6*sizeof(double)))
        rb_raise(rb_eArgError,"Reference anchor waypoints require six float64 values");
    const std::string first(RSTRING_PTR(first_cell_key),
                            static_cast<std::size_t>(RSTRING_LEN(first_cell_key)));
    const std::string second(RSTRING_PTR(second_cell_key),
                             static_cast<std::size_t>(RSTRING_LEN(second_cell_key)));
    double values[6];
    std::memcpy(values,RSTRING_PTR(waypoint_bytes),sizeof(values));
    for(const double value:values) if(!std::isfinite(value))
        rb_raise(rb_eArgError,"Reference waypoint coordinate is not finite");
    return protect_native_call([first,second,&values]() {
        const auto anchors=session().get_reference_waypoint_anchors(
            first,second,{values[0],values[1],values[2]},
                         {values[3],values[4],values[5]});
        if(!anchors) return Qnil;
        VALUE result=rb_ary_new_capa(2);
        for(const Vec3& item:{anchors->first,anchors->second})
        {
            VALUE point=rb_ary_new_capa(3);
            rb_ary_push(point,DBL2NUM(item.x));
            rb_ary_push(point,DBL2NUM(item.y));
            rb_ary_push(point,DBL2NUM(item.z));
            rb_ary_push(result,point);
        }
        return result;
    });
}

VALUE adjacency_native_get_reference_revision(VALUE self, VALUE cell_key)
{
    (void)self;
    StringValue(cell_key);
    const std::string key(RSTRING_PTR(cell_key),static_cast<std::size_t>(RSTRING_LEN(cell_key)));
    return protect_native_call([key]() {
        return ULL2NUM(static_cast<unsigned long long>(session().get_reference_revision(key)));
    });
}

VALUE adjacency_native_erase_reference_graphs(VALUE self, VALUE cell_keys)
{
    (void)self;
    Check_Type(cell_keys,T_ARRAY);
    return protect_native_call([cell_keys]() {
        std::vector<std::string> keys;
        const long count=RARRAY_LEN(cell_keys);
        keys.reserve(static_cast<std::size_t>(count));
        for(long index=0;index<count;++index)
        {
            VALUE key=rb_ary_entry(cell_keys,index);
            StringValue(key);
            keys.emplace_back(RSTRING_PTR(key),static_cast<std::size_t>(RSTRING_LEN(key)));
        }
        session().erase_reference_graphs(keys);
        return Qtrue;
    });
}

VALUE adjacency_native_start_adjacency_check(
    VALUE self,
    VALUE length_tolerance,
    VALUE normal_tolerance
)
{
    (void)self;
    const double length = NUM2DBL(length_tolerance);
    const double normal = NUM2DBL(normal_tolerance);
    return protect_native_call([length, normal]() {
        return ULL2NUM(static_cast<unsigned long long>(
            session().start_adjacency_check(length, normal)
        ));
    });
}

VALUE adjacency_native_get_adjacency_result_bytes(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        return bytes_to_ruby_string(session().get_adjacency_result_bytes());
    });
}

VALUE adjacency_native_start_check(VALUE self, VALUE length_tolerance, VALUE normal_tolerance)
{
    return adjacency_native_start_adjacency_check(self, length_tolerance, normal_tolerance);
}

VALUE adjacency_native_get_result_bytes(VALUE self)
{
    return adjacency_native_get_adjacency_result_bytes(self);
}

VALUE adjacency_native_get_progress(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const ProgressSnapshot progress = session().get_progress();
        VALUE result = rb_hash_new();
        hash_set(result, "phase", phase_symbol(progress.phase));
        hash_set(result, "current", ULL2NUM(static_cast<unsigned long long>(progress.current)));
        hash_set(result, "total", ULL2NUM(static_cast<unsigned long long>(progress.total)));
        hash_set(result, "candidate_count", ULL2NUM(static_cast<unsigned long long>(
            progress.phase == ProgressPhase::Adjacency ? progress.total : 0
        )));
        hash_set(result, "running", progress.running ? Qtrue : Qfalse);
        hash_set(result, "completed", progress.completed ? Qtrue : Qfalse);
        hash_set(result, "failed", progress.failed ? Qtrue : Qfalse);
        hash_set(result, "candidate_generation_duration", DBL2NUM(progress.candidate_generation_duration));
        return result;
    });
}

VALUE adjacency_native_get_metrics(VALUE self)
{
    (void)self;
    return protect_native_call([]() {
        const MetricsSnapshot metrics = session().get_metrics();
        VALUE result = rb_hash_new();

        hash_set(result, "state_target_count", ULL2NUM(static_cast<unsigned long long>(metrics.state_target_count)));
        hash_set(result, "state_success_count", ULL2NUM(static_cast<unsigned long long>(metrics.state_success_count)));
        hash_set(result, "state_volume_centroid_success_count", ULL2NUM(static_cast<unsigned long long>(metrics.state_volume_centroid_success_count)));
        hash_set(result, "state_bvh_count", ULL2NUM(static_cast<unsigned long long>(metrics.state_bvh_count)));
        hash_set(result, "state_duration", DBL2NUM(metrics.state_duration));
        hash_set(result, "state_bvh_build_duration", DBL2NUM(metrics.state_bvh_build_duration));
        hash_set(result, "state_bvh_search_duration", DBL2NUM(metrics.state_bvh_search_duration));

        hash_set(result, "candidate_count", ULL2NUM(static_cast<unsigned long long>(metrics.candidate_count)));
        hash_set(result, "adjacent_pair_count", ULL2NUM(static_cast<unsigned long long>(metrics.adjacent_pair_count)));
        hash_set(result, "failed_pair_count", ULL2NUM(static_cast<unsigned long long>(metrics.failed_pair_count)));
        hash_set(result, "candidate_generation_duration", DBL2NUM(metrics.candidate_generation_duration));
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

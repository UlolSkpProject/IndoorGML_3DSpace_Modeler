#include "native_api.h"

#if defined(_WIN32)
#define INDOOR_GML_NATIVE_EXPORT __declspec(dllexport)
#else
#define INDOOR_GML_NATIVE_EXPORT
#endif

extern "C" INDOOR_GML_NATIVE_EXPORT void Init_indoor_gml_native()
{
    VALUE ulol_module = rb_define_module("ULOL");
    VALUE modeler_module = rb_define_module_under(ulol_module, "Indoor3DGmlModeler");
    VALUE native_module = rb_define_module_under(modeler_module, "AdjacencyNative");

    rb_define_singleton_method(native_module, "load_batch", adjacency_native_load_batch, 1);

    rb_define_singleton_method(native_module, "start_state_check", adjacency_native_start_state_check, 0);
    rb_define_singleton_method(native_module, "get_state_result_bytes", adjacency_native_get_state_result_bytes, 0);

    rb_define_singleton_method(native_module, "start_adjacency_check", adjacency_native_start_adjacency_check, 2);
    rb_define_singleton_method(native_module, "get_adjacency_result_bytes", adjacency_native_get_adjacency_result_bytes, 0);

    rb_define_singleton_method(native_module, "start_check", adjacency_native_start_check, 2);
    rb_define_singleton_method(native_module, "get_result_bytes", adjacency_native_get_result_bytes, 0);

    rb_define_singleton_method(native_module, "get_progress", adjacency_native_get_progress, 0);
    rb_define_singleton_method(native_module, "get_metrics", adjacency_native_get_metrics, 0);
    rb_define_singleton_method(native_module, "clear_session", adjacency_native_clear_session, 0);
}

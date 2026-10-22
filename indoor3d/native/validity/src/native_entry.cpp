#include "native_api.h"

#if defined(_WIN32)
#define INDOOR_GML_VALIDITY_NATIVE_EXPORT __declspec(dllexport)
#else
#define INDOOR_GML_VALIDITY_NATIVE_EXPORT
#endif

extern "C" INDOOR_GML_VALIDITY_NATIVE_EXPORT void Init_indoor_gml_validity_native()
{
    VALUE ulol=rb_define_module("ULOL");
    VALUE modeler=rb_define_module_under(ulol,"Indoor3DGmlModeler");
    VALUE native=rb_define_module_under(modeler,"ValidityNative");

    rb_define_singleton_method(native,"load_batch",validity_native_load_batch,1);
    rb_define_singleton_method(native,"start_check",validity_native_start_check,3);
    rb_define_singleton_method(native,"get_progress",validity_native_get_progress,0);
    rb_define_singleton_method(native,"get_metrics",validity_native_get_metrics,0);
    rb_define_singleton_method(native,"get_result_bytes",validity_native_get_result_bytes,0);
    rb_define_singleton_method(native,"clear_session",validity_native_clear_session,0);
}

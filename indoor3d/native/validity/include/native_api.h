#pragma once

#include <ruby.h>

VALUE validity_native_load_batch(VALUE self, VALUE geometry);
VALUE validity_native_start_check(
    VALUE self,
    VALUE requests,
    VALUE overlap_tolerance,
    VALUE normal_tolerance
);
VALUE validity_native_get_progress(VALUE self);
VALUE validity_native_get_metrics(VALUE self);
VALUE validity_native_get_result_bytes(VALUE self);
VALUE validity_native_clear_session(VALUE self);

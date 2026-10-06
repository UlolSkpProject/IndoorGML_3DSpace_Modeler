#pragma once

#include <ruby.h>

VALUE adjacency_native_load_batch(VALUE self, VALUE buffer);
VALUE adjacency_native_start_check(VALUE self, VALUE length_tolerance, VALUE normal_tolerance);
VALUE adjacency_native_get_progress(VALUE self);
VALUE adjacency_native_get_result_bytes(VALUE self);
VALUE adjacency_native_get_metrics(VALUE self);
VALUE adjacency_native_clear_session(VALUE self);

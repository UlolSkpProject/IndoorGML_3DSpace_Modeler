#pragma once

#include <ruby.h>

VALUE adjacency_native_load_batch(VALUE self, VALUE buffer);
VALUE adjacency_native_set_cell_keys(VALUE self, VALUE keys);
VALUE adjacency_native_start_state_check(VALUE self);
VALUE adjacency_native_get_state_result_bytes(VALUE self);
VALUE adjacency_native_commit_reference_graph_batch(VALUE self);
VALUE adjacency_native_validate_room_los(VALUE self, VALUE cell_index, VALUE segment_bytes, VALUE tolerance);
VALUE adjacency_native_get_reference_graph(VALUE self, VALUE cell_key, VALUE stage);
VALUE adjacency_native_get_reference_transition_curve(VALUE self, VALUE first_cell_key, VALUE second_cell_key, VALUE waypoint_bytes);
VALUE adjacency_native_get_reference_revision(VALUE self, VALUE cell_key);
VALUE adjacency_native_erase_reference_graphs(VALUE self, VALUE cell_keys);
VALUE adjacency_native_start_adjacency_check(VALUE self, VALUE length_tolerance, VALUE normal_tolerance);
VALUE adjacency_native_get_adjacency_result_bytes(VALUE self);

// V1 API compatibility aliases.
VALUE adjacency_native_start_check(VALUE self, VALUE length_tolerance, VALUE normal_tolerance);
VALUE adjacency_native_get_result_bytes(VALUE self);

VALUE adjacency_native_get_progress(VALUE self);
VALUE adjacency_native_get_metrics(VALUE self);
VALUE adjacency_native_clear_session(VALUE self);

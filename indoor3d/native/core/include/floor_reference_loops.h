#pragma once
#include "cell_space_interior_point_locator.h"

namespace IndoorGMLAdjacencyNative
{
class FaceSolid;
// Optional bounded, deterministic BEFORE-cycle certification.
// Only certified hole-free rings are exposed; failure leaves BEFORE intact.
void certify_before_reference_loops(const FaceSolid& solid,
                                    ReferenceGraphDebug& graph,
                                    double tolerance) noexcept;
}

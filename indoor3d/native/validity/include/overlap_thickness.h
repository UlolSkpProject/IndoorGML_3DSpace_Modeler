#pragma once

#include <manifold/manifold.h>

namespace IndoorGMLValidityNative
{
enum class ThicknessResult
{
    Thin,
    Thick,
    Uncertain
};

ThicknessResult classify_overlap_thickness(
    const manifold::Manifold& geometry,
    double diameter_tolerance
);
} // namespace IndoorGMLValidityNative

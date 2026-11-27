#pragma once
#include <array>
#include <optional>
#include <string>
#include <vector>
#include "core/model.h"

namespace birch::core {
struct RGB { double r=0, g=0, b=0; };
struct Lab { double L=0, a=0, b=0; };
std::optional<RGB> ParseHex(const std::string& hex);
std::string Hex(RGB color);
Lab ToOKLab(RGB color);
RGB FromOKLab(Lab lab);
Lab Soften(RGB color, double intensity, bool dark, double brightness=0);
std::vector<Lab> SoftLabs(const Theme& theme, bool dark);
std::array<RGB,16> GradientStops(const Theme& theme, bool dark);
double GrainAmount(const Theme& theme);
double BrightnessAmount(const Theme& theme);
struct GrainTile { std::vector<unsigned char> rgba; };
GrainTile GenerateGrainTile();
std::string Sha256(const std::vector<unsigned char>& bytes);
}

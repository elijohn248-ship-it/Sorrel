# Space colours

Spec 2.0.0. Fixtures: `theme` (100 cases: all 10 presets × light/dark × brightness unset/0.5/1, plus edge cases), `theme-math` (55: hex parsing, OKLab both ways, soft bases, soften, blending, the grain tile). Sources: `ThemeLook.swift`, `Support.swift` (Theme, NSColor hex/luminance). **Tolerance: 1e-6 absolute** on every float (README).

## Theme

`{ colors: 1–3 hex strings, angle: degrees, intensity: 0…1, grain: 0…1 or null, brightness: 0…1 or null }`.

- Hex: optional `#`, surrounding spaces trimmed, exactly 6 hex digits, read as **sRGB**. Anything else is dropped (`#FFF` is invalid). Written uppercase `#RRGGBB` with each channel `round(x·255)`.
- `grainAmount = clamp(grain ?? 0.35, 0, 1)`; `brightnessAmount = clamp(brightness ?? 0, 0, 1)`; `intensity` is clamped where used. Null brightness keeps older spaces' soft look.

## OKLab

Björn Ottosson's OKLab with the exact matrices in `ThemeLook.swift` (sRGB decode: `x ≤ 0.04045 ? x/12.92 : ((x+0.055)/1.055)^2.4`; cube roots). Back to sRGB: clamp L to 0…1, convert; while any linear channel is < −0.0005 or > 1.0005, multiply a and b by 0.92 (at most 24 times); clamp channels to 0…1 and encode (`x ≤ 0.0031308 ? 12.92x : 1.055·x^(1/2.4) − 0.055`).

## Softening one colour (`Theme.soften(color, intensity, dark, brightness)`)

1. `lab = OKLab(color)`, `original = lab`, `c = chroma = √(a²+b²)`.
2. If c > 0.0001: scale a, b so chroma becomes `0.15 · tanh(c / 0.15) · 0.9`.
3. Dark mode: `L = min(L, 0.3 + 0.2·L)`.
4. `lab = mix(lab, original, brightnessAmount)` (component-wise linear).
5. Result = `mix(softBase(dark), lab, clamp(intensity, 0, 1))`, where softBase is white `(L 1, a 0, b 0)` in light mode and OKLab of sRGB `(0.12, 0.12, 0.14)` in dark mode.

`softLabs` = each valid colour softened; no valid colour → `[softBase]`. **Resolved colours** = those converted to sRGB. **is_dark** (text drawn light) = mean of `0.2126R + 0.7152G + 0.0722B` over resolved colours, using **gamma-encoded** sRGB components, < 0.55.

## Gradient

Always **16 stops** (so two spaces blend stop by stop during a swipe). One colour becomes two: `L + 0.025` (max 1) at the start and `L − 0.025` (min 0) at the end. For stop k (0…15): `u = k/15 · (n−1)`, `i = min(floor(u), n−2)`, `f = u − i`, `eased = 0.5f + 0.5·f²(3−2f)`, stop = sRGB of `mix(labs[i], labs[i+1], eased)`.

Direction: angle θ in degrees; start point `(0.5 − cos θ/2, 0.5 − sin θ/2)`, end `(0.5 + cos θ/2, 0.5 + sin θ/2)` in unit coordinates of the layer with **y up** (Core Animation on macOS). Stops are evenly spaced along that line. (Read from code: `ThemeBackgroundView.ends`; no fixture.)

Blending two themes at fraction f (space swipe): mix each pair of stops' OKLab values by f and convert; mix start/end points and grain amounts linearly.

## Grain

A fixed 256×256 px tile drawn at 128×128 pt, repeated over the gradient, layer opacity `grainAmount × 0.32`, hidden when grainAmount ≤ 0.001. Pixels come from a 64-bit LCG (`seed = 0x5EED50FFE1`; `seed = seed·6364136223846793005 + 1442695040888963407` mod 2⁶⁴; `rand = (seed >> 11) / 2⁵³`): per pixel `n = (rand+rand+rand+rand)/4 − 0.5`, `v = clamp(3.2n, −1, 1)`, alpha = `UInt8(|v|·255)` (truncated), colour = alpha if v > 0 else 0 (premultiplied RGBA: white or black specks), row-major from the top. `theme-math ▸ grain tile` has the first 8 pixels and the SHA-256 of all 262,144 bytes.

## Presets

`Theme.presets` (new spaces cycle through them): see the 10 `preset i` inputs in `theme.json`. Preset 0 (`#8978F9 → #6CBAD9`, 315°, 0.8) is the fresh profile's Home space.

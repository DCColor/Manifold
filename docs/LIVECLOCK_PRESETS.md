LiveClock depth presets (validated 2026-07-20, synthetic sweep)

Presets (targetDepth seconds):
  Low/near-live:  0.120  (~120ms) — good networks
  Balanced:       0.150  (~150ms) — default
  Stable:         0.200  (~200ms) — rough networks

Method: auto-sweep (⌃⌥S), target × jitter grid, HD HEVC clips at
23.976 / 25.000 / 29.97, ~7min each (no loop). Pass = fpsMin ≥
srcFps×0.98 AND countMin ≥ 1 AND no overflow. Presets chosen at
countMin ≥ 2 margin off the worst-case (23.976) FAIL boundary.

Findings:
- 23.976 is the worst case (slower rate = fixed jitter is a larger
  fraction of frame interval). Higher rates strictly more forgiving
  (23.976: 4 fails, 25: 3, 29.97: 1) → 23.976 presets conservative-safe
  at all rates. Δ-normalization confirmed: boundary frame-rate-independent
  for target ≥ 0.100.
- Confounds found + eliminated during runs: codec (ProRes vs HEVC) and
  resolution (UHD vs HD) both shift decode cadence / buffer occupancy;
  all final runs held to HD HEVC so only frame rate varied.

CAVEAT (for WHEP validation): synthetic feed is no-B-frame HEVC (even
decode cadence). Real WHEP delivers B-frames + real GOP (uneven decode)
+ real network jitter. These are defensible STARTING presets; validate
and retune against a live WHEP feed. (v2 "Auto" adaptive-depth would
measure real jitter and pick depth dynamically.)
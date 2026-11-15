# Changelog

## v1.0.0-beta.1 (2026-11-14)

First public release.

- `ViewportStroke.new(viewport, model, properties?)`: a stroke object with UIStroke-style properties
  (`Color`, `Rotation`, `Thickness`, `StrokeSizingMode`, `Transparency`, `Enabled`) plus `Method`,
  `Resolution`, `RingLayers` and `Layered`. Setting a property updates the stroke; bad values error like
  an Instance's would.
- `Color` takes a `Color3` or a `ColorSequence` (gradient, angled with `Rotation`).
- Two ways to draw the stroke: `"Grow"` (default, cheapest) and `"Ring"` (exact shape for any mesh).
- `Layered` mode draws the stroke in its own flat-lit viewport, so every material and mesh (including
  old SpecialMesh parts) gets exactly the stroke color.
- Follows camera moves, field of view changes, `CurrentCamera` swaps and viewport resizes by itself.
  `:Refresh()` after moving or posing the model; `:Destroy()` puts everything back.
- `ViewportStroke.createStrokeModel(...)` for pooling: build a stroke once for a fixed camera.
- `ViewportStroke.fitCamera(...)` to frame a model in a viewport, with room for the stroke.

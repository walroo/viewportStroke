# ViewportStroke

A `UIStroke` for 3D models in `ViewportFrame`s. It draws an even outline round a model, the same
thickness on every screen, in a flat color or a gradient.

Roblox's `Highlight` doesn't draw inside ViewportFrames, and a viewport can't be read back into an
`EditableImage`, so ViewportStroke builds the outline out of geometry instead. It's one plain
`--!strict` Luau module with no dependencies.

> **Beta.** The API may still change before 1.0.0. Bug reports and ideas are welcome in Issues.

## Install

**Studio:** download `ViewportStroke.rbxm` from the
[latest release](https://github.com/walroo/ViewportStroke/releases) and drag it into Studio
(for example into `ReplicatedStorage`).

**Rojo:** copy `src/init.luau` into your project as `ViewportStroke.luau`, or add this repo as a
git submodule and point a project entry at its `src` folder.

## Usage

```lua
local ViewportStroke = require(game.ReplicatedStorage.ViewportStroke)

-- the model is already in the viewport, and the viewport has a CurrentCamera
local stroke = ViewportStroke.new(viewportFrame, model)
stroke.Color = Color3.new(0, 0, 0)
stroke.Thickness = 0.02
stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize

-- later
stroke:Destroy()
```

Or set everything at once:

```lua
local stroke = ViewportStroke.new(viewportFrame, model, {
	Color = ColorSequence.new(Color3.fromRGB(255, 80, 170), Color3.fromRGB(255, 200, 60)),
	Rotation = 90,
	Thickness = 3,
	StrokeSizingMode = Enum.StrokeSizingMode.FixedSize, -- 3 pixels
})
```

Point a camera so the model fills the viewport, with room left for the stroke:

```lua
local size = viewportFrame.AbsoluteSize
camera.CFrame = ViewportStroke.fitCamera(model, CFrame.identity, camera.FieldOfView, size.X / size.Y, 0.06)
```

## Properties

Read and set them like an Instance's properties; the stroke updates itself. Setting a wrong type
errors the way an Instance would (`ViewportStroke.Color expects a Color3 or ColorSequence, got number`).

| Property | Type | Default | Notes |
| --- | --- | --- | --- |
| `Color` | `Color3 \| ColorSequence` | black | A `ColorSequence` draws a gradient. |
| `Rotation` | `number` | `0` | The gradient's angle, like `UIGradient.Rotation`. |
| `Thickness` | `number` | `0.02` | `ScaledSize`: a fraction of the viewport's smaller side. `FixedSize`: pixels. |
| `StrokeSizingMode` | `Enum.StrokeSizingMode` | `ScaledSize` | Same as `UIStroke`. |
| `Transparency` | `number` | `0` | |
| `Enabled` | `boolean` | `true` | |
| `Method` | `"Grow" \| "Ring"` | `"Grow"` | How the stroke is built (see below). |
| `Resolution` | `number` | `8` | Ring only: copies round each circle. Higher is smoother and costs more. |
| `RingLayers` | `number` | `2` | Ring only: circles from the edge inwards. Fills gaps next to very thin parts. |
| `Layered` | `boolean` | `false` | Draws the stroke in its own flat-lit viewport, for exact colors on every material. |
| `Viewport` | `ViewportFrame` | | Read-only. |
| `Model` | `Instance` | | Read-only. |

## Methods

- `stroke:Refresh()`: lines the stroke up again after you move or pose the model. Camera moves, field
  of view changes, `CurrentCamera` swaps and viewport resizes are followed by themselves.
- `stroke:Destroy()`: removes the stroke and puts everything back. It also runs when the model is
  destroyed.

## Lower level

- `ViewportStroke.createStrokeModel(model, cameraCFrame, fieldOfView, properties?) -> WorldModel`
  builds the stroke for one fixed camera, to parent next to the model in the same viewport. Useful for
  pooling: build once, reuse. `Thickness` here is a fraction of the viewport's height, and `Color` must
  be a `Color3`.
- `ViewportStroke.fitCamera(model, rotation, fieldOfView, aspectRatio?, padding?) -> CFrame` returns a
  camera CFrame looking the way `rotation` faces, centred on the model and backed off only as far as its
  corners need. `padding` is empty space round the model as a fraction of the view (default `0.05`).

## How it works

1. A copy of the model is scaled up around the camera. Scaling around the camera keeps every point on
   the same line of sight, so on screen the copy covers exactly the model's shape, just further away.
2. The copy is pushed behind the whole model, drawn in one flat color, and made to stick out past the
   model's edges:
   - **Grow** (default): every part of the copy is made a little bigger. Cheapest, but each part grows
     as a box round its centre, so very thin, hollow or curved meshes can come out a bit blocky. Wedges
     are built from 7 parts so their tips get a clean rounded cap.
   - **Ring**: exact copies, nothing resized, nudged sideways on screen in a circle (`Resolution` copies
     per circle, `RingLayers` circles). Follows any mesh's real shape, but costs
     `Resolution × RingLayers` times the parts.
3. The model hides the middle, so only a thin edge shows round it: the stroke.

The stroke is Neon so lighting can't shade it. Neon brightens colors in viewports, so colors are scaled
down first (black and white are exact, other colors land close). Old-style parts with a `SpecialMesh`
ignore Material and get shaded; use `Layered = true` for those.

**Layered mode** (on with `Layered = true`, and always with a `ColorSequence` or `Transparency` above 0)
adds two ViewportFrames inside yours, filling it: `StrokeLayer` (the stroke, lit flat so every part is
exactly its color, tinted by the gradient) and `ModelLayer` in front (your model moves into it and goes
back on `Destroy`). Your viewport stays the container and keeps its background, so layouts and ZIndex
modes are unaffected. Two viewports cost more to draw than one.

## Performance

Measured in Studio (numbers vary by machine):

- Building a stroke for a ~20-part model: about 1.8 ms. Lining it up again: about 0.04 ms.
- 12 R15 viewports with still cameras: 60 fps with or without strokes, Grow or Ring.
- 12 R15 viewports with cameras spinning every frame: about 24 ms a frame with Grow and about 87 ms
  with Ring (vs 17 ms with no strokes). Most of Ring's cost is drawing its extra copies.

So: **Grow** for moving cameras or many viewports, **Ring** for a few still viewports or odd meshes.

## Limits

- The stroke is made for one camera position and pose. Camera changes are followed; call `Refresh()`
  after moving or animating the model.
- Parts with `Transparency` 1 are left out (like `HumanoidRootPart`).
- Ring with few copies gives faceted corners and star-shaped needle tips; raise `Resolution`.

## License

MIT, see [LICENSE](LICENSE).

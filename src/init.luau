--!strict
--[[
	ViewportStroke
	A UIStroke for 3D models in ViewportFrames: an even outline round the model, the same thickness on every
	screen, in a flat color or a gradient.

	Roblox's Highlight doesn't draw inside ViewportFrames, and a viewport can't be read back into an
	EditableImage, so the stroke is drawn with geometry instead:

	  1. A copy of the model is scaled up around the camera. Scaling around the camera keeps every point on
	     the same line of sight, so on screen the copy covers exactly the model's shape, just further away.
	  2. It is pushed behind the whole model, drawn in one flat color, and made to stick out past the model's
	     edges in one of two ways (Method):
	       "Grow" (default): every part of the one copy is made a little bigger. Cheapest, but each part
	                 grows as a box round its centre, so odd meshes (thin, hollow, curved) can come out blobby.
	       "Ring":   exact copies, nothing resized, nudged sideways on screen in a circle (Resolution copies
	                 per circle, RingLayers circles from the edge inwards). Follows any mesh's real shape;
	                 costs Resolution x RingLayers times the parts.
	  3. The model hides the middle, so only a thin edge shows round it: the stroke.

	USAGE
		local ViewportStroke = require(path.to.ViewportStroke)

		-- the model is already in the viewport, and the viewport has a CurrentCamera
		local stroke = ViewportStroke.new(viewportFrame, model)
		stroke.Color = Color3.new(0, 0, 0)            -- or a ColorSequence for a gradient
		stroke.Thickness = 0.02
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
		stroke:Destroy()

		-- or all at once
		local stroke = ViewportStroke.new(viewportFrame, model, {
			Color = ColorSequence.new(Color3.fromRGB(255, 80, 170), Color3.fromRGB(255, 200, 60)),
			Rotation = 90,
			Thickness = 3,
			StrokeSizingMode = Enum.StrokeSizingMode.FixedSize,
		})

		-- optional: point a camera so a model fills the viewport (leave room for the stroke with padding)
		camera.CFrame = ViewportStroke.fitCamera(model, CFrame.identity, camera.FieldOfView, aspectRatio, 0.06)

	PROPERTIES (read and set them like an Instance's; the stroke updates itself)
		Color             Color3 | ColorSequence   black. A ColorSequence draws a gradient (see Rotation).
		Rotation          number                   0. The gradient's angle, like UIGradient.Rotation.
		Thickness         number                   0.02. With ScaledSize a fraction of the viewport's
		                                           smaller side, with FixedSize pixels.
		StrokeSizingMode  Enum.StrokeSizingMode     ScaledSize (the same share of the viewport on every
		                                           screen) or FixedSize (pixels).
		Transparency      number                   0.
		Enabled           boolean                  true.
		Method            "Grow" | "Ring"          "Grow".
		Resolution        number                   8. Ring only: copies round each circle; higher = smoother
		                                           corners and sharp tips, costs more.
		RingLayers        number                   2. Ring only: circles from the edge inwards; the inner
		                                           one fills gaps next to parts thinner than the stroke.
		Layered           boolean                  false. Draw the stroke in its own flat-lit viewport:
		                                           exact colors on every material and mesh.
	METHODS
		stroke:Refresh()   line it up again after moving or posing the model (camera moves and viewport
		                   resizes are followed by themselves)
		stroke:Destroy()

	LOWER LEVEL (pooling): ViewportStroke.createStrokeModel(model, cameraCFrame, fieldOfView, properties)
	builds the stroke for one fixed camera as a WorldModel to parent next to the model in the same viewport.
	Its Thickness is a fraction of the viewport's height; Color must be a Color3.

	LIMITS
		The stroke is made for one camera position and pose: camera changes are followed, call Refresh()
		after moving the model. Parts with Transparency 1 are left out (like HumanoidRootPart).
		Grow: boxes, balls and cylinders grow exactly. Wedges are built from 7 parts (the wedge, a slab on
		each face and a cylinder on each corner), so sharp tips get a rounded cap. MeshParts and other shapes
		grow round their centres, so very thin or hollow meshes get a slightly blocky edge.
		Ring: exact for every shape. Few copies give faceted corners and star-shaped needle tips (raise
		Resolution). Fine for still viewports; heavy when the camera moves every frame (12 spinning R15
		viewports: ~11 fps, vs ~40 fps with Grow), because every copy is drawn again.

		COLOR. In your viewport the stroke is Neon, so lighting can't shade it; Neon brightens colors in
		viewports, so the color is scaled by NEON_CORRECTION first (black and white exact, other colors close).
		Old-style parts with a SpecialMesh (many hats and tools) ignore Material and get shaded: use Layered.

		LAYERED (Layered = true, and always with a ColorSequence or Transparency above 0). The stroke gets its
		own viewport, so two ViewportFrames go inside yours, filling it: the stroke, lit flat (every material
		and mesh exactly its color) and tinted by the gradient, and in front the model, which moves into it
		(it goes back on Destroy). Your viewport stays the container and keeps its background, so layouts and
		ZIndex modes are unaffected. Two viewports cost more to draw than one.

	MIT License, see LICENSE.
]]

-- one source part and an outline part made for it (plus six more for a wedge, with "grow")
type PartPair = {
	source: BasePart,
	copy: BasePart,
	wedge: WedgeParts?,
	-- "ring" only: which way and how far this copy is nudged on screen (x right, y up; length 1 = the
	-- full thickness)
	ring: Vector2?,
	sourceMesh: SpecialMesh?,
	copyMesh: SpecialMesh?,
}

-- extra outline parts round a wedge: a slab on each face and a cylinder on each corner of its triangle
type WedgeParts = {
	back: BasePart,
	bottom: BasePart,
	slope: BasePart,
	top: BasePart,
	corner: BasePart,
	front: BasePart,
}

local DEFAULT_THICKNESS: number = 0.02
local DEFAULT_COLOR: Color3 = Color3.new(0, 0, 0)
local DEFAULT_RESOLUTION: number = 8
local DEFAULT_RING_LAYERS: number = 2
-- the copy's nearest point sits this much further away than the model's farthest point
local DEPTH_MARGIN: number = 1.15
-- Neon shows colors brighter in viewports; scaling by this first lands close to the color asked for
-- (measured side by side with a Frame of the same color)
local NEON_CORRECTION: number = 0.72

-- Enum.PartType.Wedge only exists on newer clients; nil if it doesn't
local WEDGE_SHAPE: Enum.PartType? = (function(): Enum.PartType?
	local ok: boolean, shape: any = pcall(function()
		return (Enum.PartType :: any).Wedge
	end)
	return if ok then shape else nil
end)()

local CORNERS: { Vector3 } = {
	Vector3.new(1, 1, 1), Vector3.new(1, 1, -1), Vector3.new(1, -1, 1), Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1), Vector3.new(-1, 1, -1), Vector3.new(-1, -1, 1), Vector3.new(-1, -1, -1),
}

-- children kept on the copies (they give the part its shape); everything else is stripped
local function keepsShape(child: Instance): boolean
	return child:IsA("SpecialMesh")
end

local function visibleParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") and root.Transparency < 1 then
		table.insert(parts, root)
	end
	for _, descendant: Instance in root:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Transparency < 1 then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function isWedge(part: BasePart): boolean
	if part:IsA("WedgePart") then
		return true
	end
	return WEDGE_SHAPE ~= nil and part:IsA("Part") and part.Shape == WEDGE_SHAPE
end

-- Resizing a part costs much more than moving it, and while a camera turns the sizes barely change, so
-- sizes within RESIZE_TOLERANCE (fraction of the size) of the current one are left alone.
local RESIZE_TOLERANCE: number = 0.002
local function resize(part: BasePart, size: Vector3): boolean
	local current: Vector3 = part.Size
	if (current - size).Magnitude <= size.Magnitude * RESIZE_TOLERANCE then
		return false
	end
	part.Size = size
	return true
end

-- How outline parts are colored.
-- In the model's own viewport: Neon (drawn without shading, so lighting can't shade it), color scaled by
-- NEON_CORRECTION. In a flat-lit layer (layered): plain SmoothPlastic in the exact color; the layer's light
-- (white ambient, no directional light) leaves every material and mesh exactly that color.
type Paint = { color: Color3, material: Enum.Material }

local function paintFor(color: Color3, layered: boolean): Paint
	if layered then
		return { color = color, material = Enum.Material.SmoothPlastic }
	end
	return {
		color = Color3.new(color.R * NEON_CORRECTION, color.G * NEON_CORRECTION, color.B * NEON_CORRECTION),
		material = Enum.Material.Neon,
	}
end

-- settings every outline part shares: one flat color, no physics, no shadow
local function flatten(part: BasePart, paint: Paint): ()
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 0
	part.Reflectance = 0
	part.Color = paint.color
	part.Material = paint.material
end

local function newPart(shape: Enum.PartType, color: Paint): Part
	local part: Part = Instance.new("Part")
	part.Shape = shape
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	flatten(part, color)
	return part
end

-- A wedge's outline is the wedge pushed out by `fatten` on every side, with round corners: its own shape,
-- a slab along each of the three faces of its triangle, and a cylinder on each corner. (Growing a wedge
-- around its centre slides its tip sideways; growing it round its incentre makes a long spike.)
-- The triangle (wedge's own axes): tall back at +Z, slope down to the front at -Z, right angle at the
-- back-bottom. Sets every part's size and CFrame given the wedge's size and CFrame.
local function placeWedge(parts: WedgeParts, main: BasePart, size: Vector3, cframe: CFrame, fatten: number): ()
	local width: number = size.X + fatten * 2
	local height: number = size.Y
	local depth: number = size.Z
	local slopeLength: number = math.sqrt(height * height + depth * depth)

	resize(main, Vector3.new(width, height, depth))
	main.CFrame = cframe

	-- slabs on the back and bottom faces
	resize(parts.back, Vector3.new(width, height, fatten))
	parts.back.CFrame = cframe * CFrame.new(0, 0, depth / 2 + fatten / 2)
	resize(parts.bottom, Vector3.new(width, fatten, depth))
	parts.bottom.CFrame = cframe * CFrame.new(0, -height / 2 - fatten / 2, 0)

	-- slab on the slope: its up axis is the slope's outward normal (pointing away from the right angle)
	if slopeLength > 0 then
		local normal: Vector3 = Vector3.new(0, depth, -height) / slopeLength
		local along: Vector3 = Vector3.xAxis:Cross(normal)
		resize(parts.slope, Vector3.new(width, fatten, slopeLength))
		parts.slope.CFrame = cframe * CFrame.fromMatrix(normal * (fatten / 2), Vector3.xAxis, normal, along)
	end

	-- round corners: cylinders (their length runs along X, like the wedge's width)
	local round: Vector3 = Vector3.new(width, fatten * 2, fatten * 2)
	resize(parts.top, round)
	parts.top.CFrame = cframe * CFrame.new(0, height / 2, depth / 2)
	resize(parts.corner, round)
	parts.corner.CFrame = cframe * CFrame.new(0, -height / 2, depth / 2)
	resize(parts.front, round)
	parts.front.CFrame = cframe * CFrame.new(0, -height / 2, -depth / 2)
end

local function wedgeParts(color: Paint): WedgeParts
	return {
		back = newPart(Enum.PartType.Block, color),
		bottom = newPart(Enum.PartType.Block, color),
		slope = newPart(Enum.PartType.Block, color),
		top = newPart(Enum.PartType.Cylinder, color),
		corner = newPart(Enum.PartType.Cylinder, color),
		front = newPart(Enum.PartType.Cylinder, color),
	}
end

-- a flat-colored copy of one part's shape
local function copyShape(part: BasePart, color: Paint): (BasePart, SpecialMesh?, SpecialMesh?)
	local archivable: boolean = part.Archivable
	part.Archivable = true
	local copy: BasePart = part:Clone()
	part.Archivable = archivable

	for _, child: Instance in copy:GetChildren() do
		if not keepsShape(child) then
			child:Destroy()
		end
	end

	flatten(copy, color)
	if copy:IsA("MeshPart") then
		copy.TextureID = ""
	end

	local sourceMesh: SpecialMesh? = part:FindFirstChildOfClass("SpecialMesh")
	local copyMesh: SpecialMesh? = copy:FindFirstChildOfClass("SpecialMesh")
	if copyMesh then
		copyMesh.TextureId = ""
	end
	return copy, sourceMesh, copyMesh
end

-- puts every copy behind the model, lined up with it from the camera, and makes it stick out by `thickness`
-- (grown, or nudged sideways for "ring" copies)
local function place(
	pairs: { PartPair },
	camera: CFrame,
	fieldOfView: number,
	thickness: number,
	container: Instance
): ()
	local eye: Vector3 = camera.Position
	local look: Vector3 = camera.LookVector
	local right: Vector3 = camera.RightVector
	local up: Vector3 = camera.UpVector

	-- how deep the model reaches, seen from the camera ("ring" copies repeat the same sources)
	local nearest: number = math.huge
	local farthest: number = 0
	local measured: { [BasePart]: boolean } = {}
	for _, pair: PartPair in pairs do
		if measured[pair.source] then
			continue
		end
		measured[pair.source] = true
		local half: Vector3 = pair.source.Size / 2
		for _, corner: Vector3 in CORNERS do
			local depth: number = (pair.source.CFrame:PointToWorldSpace(half * corner) - eye):Dot(look)
			nearest = math.min(nearest, depth)
			farthest = math.max(farthest, depth)
		end
	end
	nearest = math.max(nearest, 0.01)
	local scale: number = math.max(farthest / nearest, 1) * DEPTH_MARGIN

	-- the viewport's height at distance d is 2 * d * tan(fov / 2); fatten each part by `thickness` of that.
	-- Worked out once per source part ("ring" has many copies of each).
	local heightPerDepth: number = 2 * math.tan(math.rad(fieldOfView / 2))
	local baseCFrame: { [BasePart]: CFrame } = {}
	local baseFatten: { [BasePart]: number } = {}
	for source: BasePart in measured do
		local position: Vector3 = eye + (source.Position - eye) * scale
		baseCFrame[source] = source.CFrame.Rotation + position
		baseFatten[source] = thickness * heightPerDepth * (position - eye):Dot(look)
	end

	-- every new CFrame is collected and applied in one go (BulkMoveTo, when the outline is a WorldModel)
	local moveParts: { BasePart } = table.create(#pairs)
	local moveTo: { CFrame } = table.create(#pairs)

	for _, pair: PartPair in pairs do
		local source: BasePart = pair.source
		local cframe: CFrame = baseCFrame[source]
		local fatten: number = baseFatten[source]

		-- "ring": the exact shape, nudged sideways by `thickness` of the viewport (fatten studs at this depth)
		local ring: Vector2? = pair.ring
		if ring then
			local resized: boolean = resize(pair.copy, source.Size * scale)
			table.insert(moveParts, pair.copy)
			table.insert(moveTo, cframe + (right * ring.X + up * ring.Y) * fatten)
			local sourceMesh: SpecialMesh? = pair.sourceMesh
			local copyMesh: SpecialMesh? = pair.copyMesh
			if resized and sourceMesh and copyMesh and sourceMesh.MeshType == Enum.MeshType.FileMesh then
				copyMesh.Scale = sourceMesh.Scale * scale
			end
			continue
		end

		local wedge: WedgeParts? = pair.wedge
		if wedge then
			placeWedge(wedge, pair.copy, source.Size * scale, cframe, fatten)
			continue
		end

		local size: Vector3 = source.Size * scale + Vector3.one * (fatten * 2)
		local resized: boolean = resize(pair.copy, size)
		table.insert(moveParts, pair.copy)
		table.insert(moveTo, cframe)

		-- file meshes are sized by their own Scale, not the part's size
		local sourceMesh: SpecialMesh? = pair.sourceMesh
		local copyMesh: SpecialMesh? = pair.copyMesh
		if resized and sourceMesh and copyMesh and sourceMesh.MeshType == Enum.MeshType.FileMesh then
			copyMesh.Scale = sourceMesh.Scale * (size / source.Size)
		end
	end

	if container:IsA("WorldRoot") then
		container:BulkMoveTo(moveParts, moveTo, Enum.BulkMoveMode.FireCFrameChanged)
	else
		for index: number, part: BasePart in moveParts do
			part.CFrame = moveTo[index]
		end
	end
end

-- one "grow" copy of a part (plus six more pieces for a wedge)
local function growPair(part: BasePart, color: Paint, outline: Instance): PartPair
	local copy: BasePart, sourceMesh: SpecialMesh?, copyMesh: SpecialMesh? = copyShape(part, color)
	copy.Parent = outline
	local wedge: WedgeParts? = nil
	if isWedge(part) then
		local extra: WedgeParts = wedgeParts(color)
		for _, piece: BasePart in extra :: any do
			piece.Parent = outline
		end
		wedge = extra
	end
	return { source = part, copy = copy, wedge = wedge, sourceMesh = sourceMesh, copyMesh = copyMesh }
end

local function build(
	model: Instance,
	baseColor: Color3,
	method: string,
	resolution: number,
	ringLayers: number,
	layered: boolean
): (WorldModel, { PartPair })
	local color: Paint = paintFor(baseColor, layered)
	-- a WorldModel (not a plain Model) so place() can move every part in one BulkMoveTo call
	local outline: WorldModel = Instance.new("WorldModel")
	outline.Name = "ViewportStroke"
	local pairs: { PartPair } = {}

	if method == "ring" then
		local count: number = math.max(math.floor(resolution), 3)
		local layers: number = math.max(math.floor(ringLayers), 1)
		local parts: { BasePart } = visibleParts(model)

		-- one flat-colored copy of the model, then whole-model clones of it for the other ring positions
		-- (one Clone call per copy instead of copying every part again)
		local template: Model = Instance.new("Model")
		local sourceMeshes: { SpecialMesh? } = {}
		for index: number, part: BasePart in parts do
			local copy: BasePart, sourceMesh: SpecialMesh? = copyShape(part, color)
			copy.Name = tostring(index)
			copy.Parent = template
			sourceMeshes[index] = sourceMesh
		end

		local first: boolean = true
		for layer: number = 1, layers do
			-- outer circle at the full thickness, inner ones evenly closer in
			local reach: number = (layers - layer + 1) / layers
			for step: number = 1, count do
				-- inner circles turned half a step so their copies sit between the outer ones
				local angle: number = (step - 1 + (layer - 1) * 0.5) / count * math.pi * 2
				local nudge: Vector2 = Vector2.new(math.cos(angle), math.sin(angle)) * reach
				local set: Model = if first then template else template:Clone()
				first = false
				set.Name = `Ring{layer}_{step}`
				set.Parent = outline
				for index: number, part: BasePart in parts do
					local copy: BasePart = set:FindFirstChild(tostring(index)) :: BasePart
					table.insert(pairs, {
						source = part,
						copy = copy,
						ring = nudge,
						sourceMesh = sourceMeshes[index],
						copyMesh = copy:FindFirstChildOfClass("SpecialMesh"),
					})
				end
			end
		end
		return outline, pairs
	end

	for _, part: BasePart in visibleParts(model) do
		table.insert(pairs, growPair(part, color, outline))
	end
	return outline, pairs
end

------------------------------------------------------------------------------------------------------------
-- Public API

export type Method = "Grow" | "Ring"

-- every property ViewportStroke.new takes (all optional); a stroke has the same ones to read and set
export type Properties = {
	Color: (Color3 | ColorSequence)?,
	Rotation: number?,
	Thickness: number?,
	StrokeSizingMode: Enum.StrokeSizingMode?,
	Transparency: number?,
	Enabled: boolean?,
	Method: Method?,
	Resolution: number?,
	RingLayers: number?,
	Layered: boolean?,
}

local DEFAULTS: { [string]: any } = {
	Color = DEFAULT_COLOR,
	Rotation = 0,
	Thickness = DEFAULT_THICKNESS,
	StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
	Transparency = 0,
	Enabled = true,
	Method = "Grow",
	Resolution = DEFAULT_RESOLUTION,
	RingLayers = DEFAULT_RING_LAYERS,
	Layered = false,
}

-- checks a property's new value; returns an error message, or nil if it's fine
local CHECKS: { [string]: (any) -> string? } = {
	Color = function(value: any): string?
		local kind: string = typeof(value)
		return if kind == "Color3" or kind == "ColorSequence" then nil else "expects a Color3 or ColorSequence"
	end,
	Rotation = function(value: any): string?
		return if type(value) == "number" then nil else "expects a number"
	end,
	Thickness = function(value: any): string?
		return if type(value) == "number" and value >= 0 then nil else "expects a number of at least 0"
	end,
	StrokeSizingMode = function(value: any): string?
		return if typeof(value) == "EnumItem" and value.EnumType == Enum.StrokeSizingMode
			then nil
			else "expects an Enum.StrokeSizingMode"
	end,
	Transparency = function(value: any): string?
		return if type(value) == "number" and value >= 0 and value <= 1 then nil else "expects a number from 0 to 1"
	end,
	Enabled = function(value: any): string?
		return if type(value) == "boolean" then nil else "expects a boolean"
	end,
	Method = function(value: any): string?
		return if value == "Grow" or value == "Ring" then nil else 'expects "Grow" or "Ring"'
	end,
	Resolution = function(value: any): string?
		return if type(value) == "number" and value >= 3 then nil else "expects a number of at least 3"
	end,
	RingLayers = function(value: any): string?
		return if type(value) == "number" and value >= 1 then nil else "expects a number of at least 1"
	end,
	Layered = function(value: any): string?
		return if type(value) == "boolean" then nil else "expects a boolean"
	end,
}

type State = {
	viewport: ViewportFrame,
	model: Instance,
	props: { [string]: any },
	outline: WorldModel?,
	pairs: { PartPair },
	connections: { RBXScriptConnection },
	cameraConnections: { RBXScriptConnection },
	-- layered strokes only: the inner viewport the stroke is drawn in (and its UIGradient), the inner
	-- viewport the model moved into (in front), where the model was before, and their connections
	layer: ViewportFrame?,
	gradient: UIGradient?,
	front: ViewportFrame?,
	modelParent: Instance?,
	layerConnections: { RBXScriptConnection },
	destroyed: boolean,
}

local ViewportStroke = {}

-- the state behind each stroke object (weak keys: dropped with the object)
local states: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any

local function needsLayers(state: State): boolean
	local props: { [string]: any } = state.props
	return props.Layered or typeof(props.Color) == "ColorSequence" or props.Transparency > 0
end

-- the stroke's thickness as a fraction of the viewport's height (what place() works in)
local function heightFraction(state: State): number
	local props: { [string]: any } = state.props
	local size: Vector2 = state.viewport.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		-- not laid out yet: ScaledSize can still be drawn, FixedSize waits for a size
		return if props.StrokeSizingMode == Enum.StrokeSizingMode.FixedSize then 0 else props.Thickness
	end
	if props.StrokeSizingMode == Enum.StrokeSizingMode.FixedSize then
		return props.Thickness / size.Y
	end
	return props.Thickness * math.min(size.X, size.Y) / size.Y
end

local function strokeColor(state: State): Color3
	local color: any = state.props.Color
	-- a gradient tints a white stroke
	return if typeof(color) == "Color3" then color else Color3.new(1, 1, 1)
end

-- what the inner viewports copy from the outer one
local LIGHTING: { string } = { "Ambient", "LightColor", "LightDirection" }

local function innerViewport(name: string, viewport: ViewportFrame): ViewportFrame
	local inner: ViewportFrame = Instance.new("ViewportFrame")
	inner.Name = name
	inner.Size = UDim2.fromScale(1, 1)
	inner.BackgroundTransparency = 1
	inner.ZIndex = viewport.ZIndex
	inner.CurrentCamera = viewport.CurrentCamera
	return inner
end

-- keeps the inner viewports looking like the outer one (fade, tint, lighting, ZIndex)
local function mirror(state: State): ()
	local viewport: ViewportFrame = state.viewport
	local layer: ViewportFrame?, front: ViewportFrame? = state.layer, state.front
	if not layer or not front then
		return
	end
	layer.ImageTransparency = 1 - (1 - viewport.ImageTransparency) * (1 - state.props.Transparency)
	layer.ImageColor3 = viewport.ImageColor3
	front.ImageTransparency = viewport.ImageTransparency
	front.ImageColor3 = viewport.ImageColor3
	for _, property: string in LIGHTING do
		(front :: any)[property] = (viewport :: any)[property]
	end
	layer.ZIndex = viewport.ZIndex
	front.ZIndex = viewport.ZIndex
end

-- Layered strokes: two ViewportFrames inside the viewport, filling it. "StrokeLayer" draws the stroke lit
-- flat (white ambient, no directional light) so every material and mesh is exactly its color, tinted by the
-- gradient if any; "ModelLayer", added after so it draws on top, holds the model.
local function addLayers(state: State): ()
	local viewport: ViewportFrame = state.viewport
	local layer: ViewportFrame = innerViewport("StrokeLayer", viewport)
	layer.Ambient = Color3.new(1, 1, 1)
	layer.LightColor = Color3.new(0, 0, 0)
	layer.Parent = viewport
	local front: ViewportFrame = innerViewport("ModelLayer", viewport)
	front.Parent = viewport

	state.layer = layer
	state.front = front
	state.modelParent = state.model.Parent
	state.model.Parent = front
	mirror(state)
	for _, property: string in { "ImageTransparency", "ImageColor3", "ZIndex", table.unpack(LIGHTING) } do
		table.insert(state.layerConnections, viewport:GetPropertyChangedSignal(property):Connect(function()
			mirror(state)
		end))
	end
end

local function removeLayers(state: State): ()
	for _, connection: RBXScriptConnection in state.layerConnections do
		connection:Disconnect()
	end
	table.clear(state.layerConnections)
	if state.front then
		if state.model.Parent == state.front then
			state.model.Parent = state.modelParent
		end
		state.front:Destroy()
	end
	if state.layer then
		state.layer:Destroy()
	end
	state.front, state.layer, state.gradient, state.modelParent = nil, nil, nil, nil
end

-- the gradient follows Color (a ColorSequence) and Rotation
local function syncGradient(state: State): ()
	local color: any = state.props.Color
	local layer: ViewportFrame? = state.layer
	if typeof(color) == "ColorSequence" and layer then
		local gradient: UIGradient = state.gradient or Instance.new("UIGradient")
		gradient.Color = color
		gradient.Rotation = state.props.Rotation
		gradient.Parent = layer
		state.gradient = gradient
	elseif state.gradient then
		state.gradient:Destroy()
		state.gradient = nil
	end
end

local function refresh(state: State): ()
	local camera: Camera? = state.viewport.CurrentCamera
	if state.destroyed or not camera then
		return
	end
	local layer: ViewportFrame? = state.layer
	if not state.props.Enabled then
		if state.outline then
			state.outline.Parent = nil
		end
		if layer then
			layer.Visible = false
		end
		return
	end
	if not state.outline then
		local props: { [string]: any } = state.props
		local outline: WorldModel, pairs: { PartPair } = build(
			state.model,
			strokeColor(state),
			string.lower(props.Method),
			props.Resolution,
			props.RingLayers,
			state.layer ~= nil
		)
		state.outline, state.pairs = outline, pairs
	end
	local outline: WorldModel = state.outline :: WorldModel
	place(state.pairs, camera.CFrame, camera.FieldOfView, heightFraction(state), outline)
	if layer then
		layer.Visible = true
		layer.CurrentCamera = camera
	end
	if state.front then
		state.front.CurrentCamera = camera
	end
	outline.Parent = layer or state.model.Parent or state.viewport
end

-- builds everything again (after a change to how the stroke is made)
local function rebuild(state: State): ()
	if state.outline then
		state.outline:Destroy()
		state.outline = nil
	end
	state.pairs = {}
	local wanted: boolean = needsLayers(state)
	if wanted and not state.layer then
		addLayers(state)
	elseif not wanted and state.layer then
		removeLayers(state)
	end
	syncGradient(state)
	mirror(state)
	refresh(state)
end

-- recolors the existing stroke parts (a Color3 change that doesn't need a rebuild)
local function recolor(state: State): ()
	local outline: WorldModel? = state.outline
	if not outline then
		return
	end
	local paint: Paint = paintFor(strokeColor(state), state.layer ~= nil)
	for _, part: Instance in outline:GetDescendants() do
		if part:IsA("BasePart") then
			part.Color = paint.color
		end
	end
end

-- what a property change needs
local function apply(state: State, key: string, old: any): ()
	local value: any = state.props[key]
	if key == "Thickness" or key == "StrokeSizingMode" or key == "Enabled" then
		refresh(state)
	elseif key == "Rotation" then
		if state.gradient then
			state.gradient.Rotation = value
		end
	elseif key == "Color" then
		if needsLayers(state) ~= (state.layer ~= nil) or typeof(value) ~= typeof(old) then
			rebuild(state)
		elseif typeof(value) == "ColorSequence" then
			syncGradient(state)
		else
			recolor(state)
		end
	elseif key == "Transparency" then
		if needsLayers(state) ~= (state.layer ~= nil) then
			rebuild(state)
		else
			mirror(state)
		end
	else
		-- Method, Resolution, RingLayers, Layered
		rebuild(state)
	end
end

local StrokeMethods = {}

-- Lines the stroke up again with the model (after moving or posing it).
function StrokeMethods.Refresh(self: any): ()
	refresh(states[self])
end

function StrokeMethods.Destroy(self: any): ()
	local state: State? = states[self]
	if not state or state.destroyed then
		return
	end
	state.destroyed = true
	for _, connection: RBXScriptConnection in state.connections do
		connection:Disconnect()
	end
	for _, connection: RBXScriptConnection in state.cameraConnections do
		connection:Disconnect()
	end
	table.clear(state.connections)
	table.clear(state.cameraConnections)
	if state.outline then
		state.outline:Destroy()
		state.outline = nil
	end
	removeLayers(state)
end

local StrokeMeta = {
	__index = function(self: any, key: string): any
		local method: any = (StrokeMethods :: any)[key]
		if method then
			return method
		end
		local state: State = states[self]
		if DEFAULTS[key] ~= nil then
			return state.props[key]
		elseif key == "Viewport" then
			return state.viewport
		elseif key == "Model" then
			return state.model
		end
		error(`{key} is not a valid member of ViewportStroke`, 2)
	end,
	__newindex = function(self: any, key: string, value: any): ()
		local check: ((any) -> string?)? = CHECKS[key]
		if not check then
			error(`{key} is not a valid member of ViewportStroke`, 2)
		end
		local problem: string? = check(value)
		if problem then
			error(`ViewportStroke.{key} {problem}, got {typeof(value)}`, 2)
		end
		local state: State = states[self]
		local old: any = state.props[key]
		if old == value then
			return
		end
		state.props[key] = value
		if not state.destroyed then
			apply(state, key, old)
		end
	end,
	__tostring = function(): string
		return "ViewportStroke"
	end,
}

export type ViewportStroke = {
	Color: Color3 | ColorSequence,
	Rotation: number,
	Thickness: number,
	StrokeSizingMode: Enum.StrokeSizingMode,
	Transparency: number,
	Enabled: boolean,
	Method: Method,
	Resolution: number,
	RingLayers: number,
	Layered: boolean,
	Viewport: ViewportFrame,
	Model: Instance,
	Refresh: (self: ViewportStroke) -> (),
	Destroy: (self: ViewportStroke) -> (),
}

-- Strokes `model` inside `viewport` (the model must be in the viewport, and the viewport needs a
-- CurrentCamera). Follows camera changes and viewport resizes by itself.
function ViewportStroke.new(viewport: ViewportFrame, model: Instance, properties: Properties?): ViewportStroke
	local props: { [string]: any } = table.clone(DEFAULTS)
	for key: string, value: any in (properties or {}) :: any do
		local check: ((any) -> string?)? = CHECKS[key]
		if not check then
			error(`{key} is not a valid member of ViewportStroke`, 2)
		end
		local problem: string? = check(value)
		if problem then
			error(`ViewportStroke.{key} {problem}, got {typeof(value)}`, 2)
		end
		props[key] = value
	end

	local state: State = {
		viewport = viewport,
		model = model,
		props = props,
		outline = nil,
		pairs = {},
		connections = {},
		cameraConnections = {},
		layer = nil,
		gradient = nil,
		front = nil,
		modelParent = nil,
		layerConnections = {},
		destroyed = false,
	}
	local stroke: any = setmetatable({}, StrokeMeta)
	states[stroke] = state

	local function watchCamera(): ()
		for _, connection: RBXScriptConnection in state.cameraConnections do
			connection:Disconnect()
		end
		table.clear(state.cameraConnections)
		local camera: Camera? = viewport.CurrentCamera
		if camera then
			table.insert(state.cameraConnections, camera:GetPropertyChangedSignal("CFrame"):Connect(function()
				refresh(state)
			end))
			table.insert(state.cameraConnections, camera:GetPropertyChangedSignal("FieldOfView"):Connect(function()
				refresh(state)
			end))
		end
		refresh(state)
	end
	table.insert(state.connections, viewport:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))
	-- FixedSize (and wide or tall viewports) depend on the viewport's size on screen
	table.insert(state.connections, viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		refresh(state)
	end))
	table.insert(state.connections, model.Destroying:Connect(function()
		stroke:Destroy()
	end))

	rebuild(state)
	watchCamera()
	return stroke
end

-- Builds the stroke for `model` as seen from a fixed camera, as a WorldModel to parent to the same
-- ViewportFrame as the model (for pooling: build once, reuse). It's only right for that camera and pose.
-- properties.Thickness is a fraction of the viewport's height; Color must be a Color3. With Layered it's
-- made for a viewport of its own behind the model's, lit flat (Ambient white, LightColor black).
function ViewportStroke.createStrokeModel(
	model: Instance,
	camera: CFrame,
	fieldOfView: number,
	properties: Properties?
): WorldModel
	local props: { [string]: any } = table.clone(DEFAULTS)
	for key: string, value: any in (properties or {}) :: any do
		props[key] = value
	end
	local color: Color3 = if typeof(props.Color) == "Color3" then props.Color else Color3.new(1, 1, 1)
	local outline: WorldModel, pairs: { PartPair } = build(
		model,
		color,
		string.lower(props.Method),
		props.Resolution,
		props.RingLayers,
		props.Layered == true
	)
	place(pairs, camera, fieldOfView, props.Thickness, outline)
	return outline
end

-- Camera CFrame that fits `model` inside a viewport: looking the way `rotation` faces, centred, backed off
-- only as far as the model's corners need. aspectRatio is the viewport's width / height (default 1);
-- padding is empty space round the model as a fraction of the view (default 0.05; leave room for the stroke).
function ViewportStroke.fitCamera(
	model: Instance,
	rotation: CFrame,
	fieldOfView: number,
	aspectRatio: number?,
	padding: number?
): CFrame
	local turn: CFrame = rotation.Rotation
	local slopeY: number = math.tan(math.rad(fieldOfView / 2)) / (1 + 2 * (padding or 0.05))
	local slopeX: number = slopeY * (aspectRatio or 1)

	-- every corner, in the camera's axes (x right, y up, looking down -z)
	local points: { Vector3 } = {}
	for _, part: BasePart in visibleParts(model) do
		local half: Vector3 = part.Size / 2
		for _, corner: Vector3 in CORNERS do
			table.insert(points, turn:PointToObjectSpace(part.CFrame:PointToWorldSpace(half * corner)))
		end
	end
	if #points == 0 then
		local pivot: Vector3 = if model:IsA("PVInstance") then model:GetPivot().Position else Vector3.zero
		return turn + (pivot - turn.LookVector * 10)
	end

	local low: Vector3 = points[1]
	local high: Vector3 = points[1]
	for _, point: Vector3 in points do
		low = low:Min(point)
		high = high:Max(point)
	end
	local center: Vector3 = (low + high) / 2

	-- a point is in view when its sideways offset <= slope * its distance in front of the camera
	local cameraZ: number = -math.huge
	for _, point: Vector3 in points do
		local across: number = math.abs(point.X - center.X) / slopeX
		local up: number = math.abs(point.Y - center.Y) / slopeY
		cameraZ = math.max(cameraZ, point.Z + math.max(across, up))
	end
	return turn * CFrame.new(center.X, center.Y, cameraZ)
end

return ViewportStroke

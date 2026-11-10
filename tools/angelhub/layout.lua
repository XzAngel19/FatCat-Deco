-- Layout introspection for the visual harness.
--
-- Appended to the same generated chunk as the mock and the hub (see
-- tools/render_angelhub.sh). Two passes:
--
--   1. measure — walk the built ScreenGui and resolve every GuiObject's
--      absolute rect (AnchorPoint, scale/offset size and position, UIListLayout,
--      UIPadding, AutomaticSize.Y).
--   2. flatten — emit pre-order (parent before child) so the renderer's
--      painter's algorithm has the right z-order.
--
-- Prints one JSON line per drawable node between LAYOUT_JSON_BEGIN/END.
-- Text is reported with its box; tools/angelhub/render.py draws a placeholder
-- bar, so this proves geometry, stacking and colour, not letterforms.

local VIEWPORT = { width = 1280, height = 720 }

local function round2(value)
	if type(value) ~= "number" then
		return 0
	end
	return math.floor(value * 100 + 0.5) / 100
end

local function colorToTable(color)
	if not color then
		return { 1, 1, 1 }
	end
	return { round2(color.R), round2(color.G), round2(color.B) }
end

---Sample a NumberSequence / ColorSequence at `t` in [0, 1].
local function sampleSequence(points, t, field)
	if not points or #points == 0 then
		return nil
	end
	local function valueOf(point)
		if field then
			return point[field]
		end
		return point.Value
	end
	if #points == 1 then
		return valueOf(points[1])
	end
	local previous = points[1]
	for index = 2, #points do
		local point = points[index]
		if t <= point.Time then
			local span = point.Time - previous.Time
			local blend = span <= 0 and 0 or (t - previous.Time) / span
			local from, to = valueOf(previous), valueOf(point)
			if type(from) == "table" then
				return {
					from.R + (to.R - from.R) * blend,
					from.G + (to.G - from.G) * blend,
					from.B + (to.B - from.B) * blend,
				}
			end
			return from + (to - from) * blend
		end
		previous = point
	end
	return valueOf(previous)
end

local function childOfClass(parent, className)
	for _, child in parent:GetChildren() do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

local function padAmount(udim, extent)
	if not udim then
		return 0
	end
	return (udim.Scale or 0) * extent + (udim.Offset or 0)
end

local function udim2(value, fallback)
	if value == nil then
		return UDim2.fromOffset(fallback or 0, fallback or 0)
	end
	return value
end

local root = { rect = { x = 0, y = 0, w = VIEWPORT.width, h = VIEWPORT.height }, children = {} }

---Pass 1: resolve rects into a tree of nodes.
local function measure(parent, rect, node)
	local padding = childOfClass(parent, "UIPadding")
	local list = childOfClass(parent, "UIListLayout")
	local inset = {
		left = padding and padAmount(padding.PaddingLeft, rect.w) or 0,
		right = padding and padAmount(padding.PaddingRight, rect.w) or 0,
		top = padding and padAmount(padding.PaddingTop, rect.h) or 0,
		bottom = padding and padAmount(padding.PaddingBottom, rect.h) or 0,
	}
	local inner = {
		x = rect.x + inset.left,
		y = rect.y + inset.top,
		w = math.max(0, rect.w - inset.left - inset.right),
		h = math.max(0, rect.h - inset.top - inset.bottom),
	}
	local gap = list and padAmount(list.Padding, inner.h) or 0

	local cursor = inner.y
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") and child.Visible ~= false then
			local size = udim2(child.Size)
			local position = udim2(child.Position)
			local anchor = child.AnchorPoint or Vector2.new(0, 0)

			local childRect = {
				w = size.X.Scale * inner.w + size.X.Offset,
				h = size.Y.Scale * inner.h + size.Y.Offset,
			}

			if list then
				childRect.x = inner.x
				childRect.y = cursor
			else
				childRect.x = inner.x + position.X.Scale * inner.w + position.X.Offset
				childRect.y = inner.y + position.Y.Scale * inner.h + position.Y.Offset
				if anchor.X ~= 0 then
					childRect.x -= childRect.w * anchor.X
				end
				if anchor.Y ~= 0 then
					childRect.y -= childRect.h * anchor.Y
				end
			end

			local childNode = {
				instance = child,
				rect = childRect,
				children = {},
				corner = childOfClass(child, "UICorner"),
				stroke = childOfClass(child, "UIStroke"),
				gradient = childOfClass(child, "UIGradient"),
				automatic = child.AutomaticSize == Enum.AutomaticSize.Y,
			}
			table.insert(node.children, childNode)

			-- Children first: an AutomaticSize.Y box needs their extent before
			-- its own height is known.
			measure(child, childRect, childNode)

			if childNode.automatic then
				local childPadding = childOfClass(child, "UIPadding")
				local bottomPad = childPadding and padAmount(childPadding.PaddingBottom, 0) or 0
				local lastBottom = childRect.y
				if #childNode.children > 0 then
					local last = childNode.children[#childNode.children]
					lastBottom = last.rect.y + last.rect.h
				end
				childRect.h = math.max(0, lastBottom - childRect.y + bottomPad)
			end

			if list then
				cursor = childRect.y + childRect.h + gap
			end
		end
	end

	node.contentBottom = cursor
	return node
end

local emitted = 0

---Pass 2: pre-order emit, so a parent is always painted before its children.
local function flatten(node)
	for _, child in node.children do
		local instance = child.instance
		local rect = child.rect
		local corner = child.corner
		local stroke = child.stroke
		local gradient = child.gradient

		local fill = colorToTable(instance.BackgroundColor3)
		local gradientAlpha = 1
		if gradient then
			local sampled = sampleSequence(gradient.Color and gradient.Color.Keypoints, 0.5)
			if sampled then
				fill = sampled
			end
			local alpha = sampleSequence(gradient.Transparency and gradient.Transparency.Keypoints, 0.5)
			if alpha then
				gradientAlpha = 1 - alpha
			end
		end

		local text = instance.Text
		if instance.ClassName == "TextBox" and instance.PlaceholderText
			and (text == nil or text == "") then
			text = instance.PlaceholderText
		end
		if instance.ClassName == "TextLabel" and (text == nil or text == "") then
			text = nil
		end

		if rect.w > 0 and rect.h > 0 then
			local parts = {}
			local function field(key, value)
				if type(value) == "string" then
					table.insert(parts, string.format('"%s":"%s"', key, (string.gsub(value, '"', "'"))))
				elseif type(value) == "number" then
					table.insert(parts, string.format('"%s":%s', key, tostring(round2(value))))
				elseif value ~= nil then
					table.insert(parts, string.format('"%s":%s', key, tostring(value)))
				end
			end

			field("class", instance.ClassName)
			field("name", instance.Name)
			field("x", rect.x)
			field("y", rect.y)
			field("w", rect.w)
			field("h", rect.h)
			field("transparency", instance.BackgroundTransparency or 0)
			field("radius", corner and corner.CornerRadius.Offset or 0)
			field("gradient_alpha", gradientAlpha)
			table.insert(parts, string.format('"fill":[%s,%s,%s]', fill[1], fill[2], fill[3]))
			if stroke then
				local strokeColor = colorToTable(stroke.Color)
				table.insert(parts, string.format(
					'"stroke":{"color":[%s,%s,%s],"transparency":%s,"thickness":%s}',
					strokeColor[1], strokeColor[2], strokeColor[3],
					tostring(round2(stroke.Transparency or 0)), tostring(round2(stroke.Thickness or 1))
				))
			end
			if text and text ~= "" then
				field("text", text)
				field("size", instance.TextSize or 12)
				local alignment = instance.TextXAlignment
				if type(alignment) == "table" then
					alignment = alignment.Name or "Center"
				end
				field("align", alignment or "Center")
				table.insert(parts, string.format('"color":[%s,%s,%s]',
					colorToTable(instance.TextColor3)[1], colorToTable(instance.TextColor3)[2],
					colorToTable(instance.TextColor3)[3]))
			end
			print("{" .. table.concat(parts, ",") .. "}")
			emitted += 1
		end

		flatten(child)
	end
end

local screen = Hub._screen
if screen then
	measure(screen, { x = 0, y = 0, w = VIEWPORT.width, h = VIEWPORT.height }, root)
	print("LAYOUT_JSON_BEGIN")
	flatten(root)
	print("LAYOUT_JSON_END")
	print("LAYOUT_NODES " .. tostring(emitted))
end

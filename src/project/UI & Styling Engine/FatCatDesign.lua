-- Fat Cat Project | UI & Styling Engine/FatCatDesign.lua
--
-- Palettes, type scale, spacing, and every animation curve in the project.
-- Pure data plus the few helpers that turn a palette name into tables.
--
--   local Design = FatCat.require("FatCatDesign")
--   Design.color("card")        -- Color3
--   Design.apply("glacier")     -- swap palette, fire design:changed
--   Design.contrast(Design.color("text"), Design.color("card"))
--
-- A component that hardcodes a Color3 is a bug: it stops following a theme
-- switch, and the design audit cannot check a colour it cannot see. Everything
-- visual reads from `Design.theme`.

local Design, Signal
Design = {}

-- ==========================================================================
-- Palettes
-- ==========================================================================
-- Same keys in every palette, so a switch is a swap and never a merge.
-- `ember` reproduces the shell in src/FatCatHub.lua exactly; the other two
-- exist because the ember accent disappears on lava maps and on bright skies,
-- and because some users want zero hue at all.

Design.palettes = {
	-- Exact copy of the shell's THEME in src/FatCatHub.lua. This is the
	-- default because the two halves of the product must open looking the
	-- same; a preset can move away from it, nothing should drift into it.
	classic = {
		backgroundTop = Color3.fromRGB(26, 26, 30),
		backgroundBottom = Color3.fromRGB(12, 12, 14),
		card = Color3.fromRGB(38, 38, 43),
		cardHover = Color3.fromRGB(47, 47, 53),
		element = Color3.fromRGB(18, 18, 20),
		elementHover = Color3.fromRGB(45, 45, 51),
		chip = Color3.fromRGB(28, 28, 32),
		section = Color3.fromRGB(17, 17, 20),
		outline = Color3.fromRGB(104, 104, 114),
		text = Color3.fromRGB(240, 240, 243),
		textOff = Color3.fromRGB(198, 198, 204),
		textDim = Color3.fromRGB(126, 126, 134),
		accent = Color3.fromRGB(236, 236, 240),
		accentAlt = Color3.fromRGB(138, 138, 148),
		positive = Color3.fromRGB(124, 222, 146),
		negative = Color3.fromRGB(232, 92, 96),
		onAccent = Color3.fromRGB(18, 18, 21),
	},
	ember = {
		backgroundTop = Color3.fromRGB(26, 26, 30),
		backgroundBottom = Color3.fromRGB(12, 12, 14),
		card = Color3.fromRGB(38, 38, 43),
		cardHover = Color3.fromRGB(47, 47, 53),
		element = Color3.fromRGB(18, 18, 20),
		elementHover = Color3.fromRGB(45, 45, 51),
		chip = Color3.fromRGB(28, 28, 32),
		section = Color3.fromRGB(17, 17, 20),
		outline = Color3.fromRGB(104, 104, 114),
		text = Color3.fromRGB(240, 240, 243),
		textOff = Color3.fromRGB(198, 198, 204),
		textDim = Color3.fromRGB(126, 126, 134),
		accent = Color3.fromRGB(255, 138, 61),
		accentAlt = Color3.fromRGB(255, 72, 96),
		positive = Color3.fromRGB(125, 222, 145),
		negative = Color3.fromRGB(232, 92, 98),
		onAccent = Color3.fromRGB(18, 18, 21),
	},
	glacier = {
		backgroundTop = Color3.fromRGB(22, 26, 34),
		backgroundBottom = Color3.fromRGB(10, 13, 18),
		card = Color3.fromRGB(34, 40, 50),
		cardHover = Color3.fromRGB(43, 51, 63),
		element = Color3.fromRGB(16, 20, 26),
		elementHover = Color3.fromRGB(40, 48, 60),
		chip = Color3.fromRGB(25, 30, 38),
		section = Color3.fromRGB(14, 18, 23),
		outline = Color3.fromRGB(98, 112, 132),
		text = Color3.fromRGB(237, 243, 250),
		textOff = Color3.fromRGB(193, 203, 216),
		textDim = Color3.fromRGB(126, 138, 154),
		accent = Color3.fromRGB(94, 194, 255),
		accentAlt = Color3.fromRGB(120, 132, 255),
		positive = Color3.fromRGB(125, 222, 145),
		negative = Color3.fromRGB(232, 92, 98),
		onAccent = Color3.fromRGB(12, 18, 24),
	},
}

Design.order = { "classic", "ember", "glacier" }
Design.current = "classic"
Design.theme = table.clone(Design.palettes.classic)

-- ==========================================================================
-- Type, spacing, radius
-- ==========================================================================
-- The same numbers the shell uses. A 13 px label must be 13 px on both sides
-- of the product or the two screens stop reading as one app.

Design.text = {
	title = 14,
	tab = 13,
	label = 13,
	value = 13,
	body = 12,
	section = 11,
	hint = 11,
	code = 11,
}

Design.radius = { window = 12, card = 8, chip = 5, field = 5, pill = 999 }

-- A 4 px grid. Every margin in the project is a multiple of it; the audit
-- reports the ones that are not.
Design.space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }

Design.fonts = {
	regular = Enum.Font.Gotham,
	medium = Enum.Font.GothamMedium,
	bold = Enum.Font.GothamBold,
	mono = Enum.Font.RobotoMono,
}

-- ==========================================================================
-- Colour access
-- ==========================================================================

---Colour from the active palette. A missing key returns magenta: impossible
---to miss in a screenshot, therefore impossible to ship by accident.
function Design.color(key)
	return Design.theme[key] or Color3.fromRGB(255, 0, 255)
end

function Design.snapshot()
	return table.clone(Design.theme)
end

---Switch palette. Returns true, or false plus the list of valid names.
function Design.apply(name)
	local palette = Design.palettes[name]
	if not palette then
		return false, ("unknown palette '%s' (have: %s)"):format(
			tostring(name), table.concat(Design.order, ", "))
	end
	Design.current = name
	Design.theme = table.clone(palette)
	if Design.changed then
		Design.changed:Fire(name)
	end
	return true
end

-- ==========================================================================
-- Colour maths
-- ==========================================================================

---Even blend between the two accents, t in 0..1. Gradients and rails use it.
function Design.accentMix(t)
	t = math.clamp(t or 0, 0, 1)
	local from, to = Design.theme.accent, Design.theme.accentAlt
	return Color3.new(
		from.R + (to.R - from.R) * t,
		from.G + (to.G - from.G) * t,
		from.B + (to.B - from.B) * t
	)
end

---Lighten (factor > 0) or darken (factor < 0), clamped at both ends.
function Design.shade(color, factor)
	if factor >= 0 then
		return Color3.new(
			color.R + (1 - color.R) * factor,
			color.G + (1 - color.G) * factor,
			color.B + (1 - color.B) * factor
		)
	end
	return Color3.new(
		color.R * (1 + factor),
		color.G * (1 + factor),
		color.B * (1 + factor)
	)
end

---WCAG relative luminance, 0..1.
local function luminance(color)
	local function channel(value)
		if value <= 0.03928 then
			return value / 12.92
		end
		return ((value + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * channel(color.R)
		+ 0.7152 * channel(color.G)
		+ 0.0722 * channel(color.B)
end
Design.luminance = luminance

---Contrast ratio between two colours, 1..21. The audit floor for HUD text is
---3:1; the Console tab shows the live number for the current palette.
function Design.contrast(a, b)
	local la, lb = luminance(a), luminance(b)
	local high, low = math.max(la, lb), math.min(la, lb)
	return (high + 0.05) / (low + 0.05)
end

---Worst contrast in the palette between a text colour and its surface.
---Returns ratio, label. Used by the Home status row.
function Design.auditContrast()
	local theme = Design.theme
	local checks = {
		{ "text on card", theme.text, theme.card },
		{ "label on element", theme.text, theme.element },
		{ "dim on background", theme.textDim, theme.backgroundTop },
		{ "accent on onAccent", theme.accent, theme.onAccent },
	}
	local worstRatio, worstLabel = math.huge, "none"
	for _, check in checks do
		local ratio = Design.contrast(check[2], check[3])
		if ratio < worstRatio then
			worstRatio, worstLabel = ratio, check[1]
		end
	end
	return worstRatio, worstLabel
end

-- ==========================================================================
-- Motion
-- ==========================================================================
-- Names, not raw TweenInfos, so reduced motion can flatten all of them in one
-- place and a component never has to import an easing style.

local function freshAnim()
	return {
		instant = TweenInfo.new(0),
		fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		medium = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		open = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		pop = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	}
end

Design.anim = freshAnim()
Design.reducedMotion = false

---TweenInfo by name. An unknown name returns `fast`, so a typo cannot
---silently disable an animation.
function Design.tween(name)
	return Design.anim[name] or Design.anim.fast
end

---Flatten every animation to zero duration (accessibility, and the harness).
function Design.setReducedMotion(reduced)
	Design.reducedMotion = reduced and true or false
	if Design.reducedMotion then
		for name in Design.anim do
			Design.anim[name] = TweenInfo.new(0)
		end
	else
		Design.anim = freshAnim()
	end
end

-- ==========================================================================
-- Surface helpers
-- ==========================================================================

---A UIGradient that fades a frame toward its edges, used on dividers and the
---window backdrop so the background does not end in a hard line.
function Design.fade(transparency, target)
	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, transparency or 1),
		NumberSequenceKeypoint.new(0.5, 0.15),
		NumberSequenceKeypoint.new(1, transparency or 1),
	})
	gradient.Parent = target
	return gradient
end

---Vertical accent gradient for a rail or a filled track.
function Design.accentGradient(target, vertical)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Design.color("accent")),
		ColorSequenceKeypoint.new(1, Design.color("accentAlt")),
	})
	gradient.Rotation = vertical and 90 or 0
	gradient.Parent = target
	return gradient
end

return function(_core, signal)
	Signal = signal
	Design.changed = Signal.new("design:changed")
	-- Colours changed: re-apply the palette to every component that asked.
	return Design
end

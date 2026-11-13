-- Fat Cat Project | Advanced Analysis/FatCatProjectiles.lua
--
-- Reads the projectile table out of a game's scripts and predicts where a
-- shot will land, so the trajectory line and the aim assist agree with the
-- game's own physics instead of a guess.
--
--   local P = FatCat.require("FatCatProjectiles")
--   P.scan()                     -- find { Speed = ..., Gravity = ... } in loaded scripts
--   P.set({ Speed = 300, Gravity = 196.2 })
--   P.lead(muzzle, target, velocity)   -- Vector3 or nil
--   P.arc(origin, direction)           -- points for a trail
--
-- Where the numbers come from. There are three sources, in order of trust:
--
--   1. the user, on the Projectiles tab: a speed and a gravity, typed in;
--   2. scanning loaded scripts for a module table that has both a speed-like
--      and a gravity-like field (see `scan`);
--   3. the engine default (workspace.Gravity, no drag).
--
-- The scan is heuristic by design: it reports candidates instead of picking
-- one, because two plausible tables in a game is a decision the user should
-- make, not this module. Nothing is written back — the table stays the game's.

local Core, Math2, Materials, Projectiles
Projectiles = {}

Projectiles.current = { Speed = 300, Gravity = 196.2, Drag = 0 }

-- Field names seen in the wild for the two numbers that matter.
local SPEED_KEYS = { "Speed", "Velocity", "MuzzleVelocity", "ProjectileSpeed", "speed", "velocity" }
local GRAVITY_KEYS = { "Gravity", "gravity", "Grav", "DropConstant", "Arc" }

-- ==========================================================================
-- Scanning
-- ==========================================================================

local function numeric(tableValue, keys)
	for _, key in keys do
		local value = tableValue[key]
		if type(value) == "number" and value > 0 then
			return value, key
		end
	end
	return nil
end

---Walk gc objects looking for tables shaped like a projectile config.
---Returns candidates: { table, speed, gravity, path }.
function Projectiles.scan(limit)
	limit = limit or 4000
	local candidates = {}
	local seen = {}
	local gc = Core.env.getgc
	if type(gc) ~= "function" then
		return candidates, "getgc is not available on this executor"
	end

	local ok, objects = pcall(gc, true)
	if not ok then
		return candidates, "getgc failed: " .. tostring(objects)
	end

	local visited = 0
	for _, object in objects do
		visited += 1
		if visited > limit then
			break
		end
		if type(object) == "table" and not seen[object] then
			seen[object] = true
			local speed, speedKey = numeric(object, SPEED_KEYS)
			if speed then
				local gravity, gravityKey = numeric(object, GRAVITY_KEYS)
				if gravity then
					table.insert(candidates, {
						table = object,
						speed = speed,
						speedKey = speedKey,
						gravity = gravity,
						gravityKey = gravityKey,
					})
					if #candidates >= 40 then
						break
					end
				end
			end
		end
	end

	return candidates
end

---Use a specific config. `values` = { Speed = number, Gravity = number }.
function Projectiles.set(values)
	if type(values) ~= "table" then
		return false, "pass a table with Speed and Gravity"
	end
	local speed = tonumber(values.Speed)
	local gravity = tonumber(values.Gravity)
	if not speed or speed <= 0 then
		return false, "Speed must be a positive number"
	end
	if not gravity then
		return false, "Gravity must be a number"
	end
	Projectiles.current = {
		Speed = speed,
		Gravity = gravity,
		Drag = tonumber(values.Drag) or 0,
	}
	return true, Projectiles.current
end

---Fall back to the engine's own gravity, with no drag.
function Projectiles.useEngineGravity()
	Projectiles.current = {
		Speed = Projectiles.current.Speed,
		Gravity = workspace.Gravity,
		Drag = 0,
	}
	return Projectiles.current
end

-- ==========================================================================
-- Prediction
-- ==========================================================================

---Lead point for the current config. Returns Vector3 or nil plus a reason.
function Projectiles.lead(muzzle, target, targetVelocity)
	if not (muzzle and target and targetVelocity) then
		return nil, "muzzle, target and velocity are required"
	end
	local config = Projectiles.current
	if config.Drag and config.Drag > 0 then
		-- With drag the closed form no longer holds; a numerical search is the
		-- honest answer, and it is cheap at this scale.
		return Projectiles.leadWithDrag(muzzle, target, targetVelocity, config)
	end
	local point = Math2.predict(muzzle, target, targetVelocity, config.Speed)
	if not point then
		return nil, ("the target outruns a %d stud/s projectile"):format(config.Speed)
	end
	return point
end

---Simulate forward in small steps, compare distance to the moving target,
---keep the closest approach. Coarse then fine: 64 steps over 3 seconds, then
---16 steps around the best one.
function Projectiles.leadWithDrag(muzzle, target, targetVelocity, config)
	local function simulate(dt, frames)
		local position = muzzle
		local velocity = (target - muzzle).Unit * config.Speed
		local bestT, bestDistance = nil, math.huge
		for frame = 1, frames do
			local t = frame * dt
			local dragFactor = math.max(0, 1 - config.Drag * t)
			position += velocity * dt * dragFactor
			local targetAt = target + targetVelocity * t
			local distance = (position - targetAt).Magnitude
			if distance < bestDistance then
				bestDistance, bestT = distance, t
			end
		end
		return bestT, bestDistance
	end

	local coarseT = simulate(3 / 64, 64)
	if not coarseT then
		return nil, "no intercept found"
	end
	-- Refine around the coarse hit.
	local start = math.max(coarseT - 3 / 64, 0)
	local best, bestDistance = nil, math.huge
	for index = 0, 16 do
		local t = start + (3 / 64) * (index / 16)
		local dragFactor = math.max(0, 1 - config.Drag * t)
		local position = muzzle + (target - muzzle).Unit * config.Speed * t * dragFactor
		local distance = (position - (target + targetVelocity * t)).Magnitude
		if distance < bestDistance then
			bestDistance, best = distance, t
		end
	end
	if not best then
		return nil, "no intercept found"
	end
	return target + targetVelocity * best
end

---Points of the arc for a trail, using the current config.
function Projectiles.arc(origin, direction, steps, duration)
	local config = Projectiles.current
	local velocity = direction.Unit * config.Speed
	duration = duration or 1.2
	steps = steps or 24
	if config.Drag and config.Drag > 0 then
		-- With drag the path is not a parabola; integrate it.
		local points = {}
		local position = origin
		local currentVelocity = velocity
		local dt = duration / steps
		for index = 0, steps do
			points[index + 1] = position
			position += currentVelocity * dt
			currentVelocity = Vector3.new(
				currentVelocity.X * (1 - config.Drag * dt),
				currentVelocity.Y + (-config.Gravity) * dt,
				currentVelocity.Z * (1 - config.Drag * dt)
			)
		end
		return points
	end
	return Math2.arc(origin, velocity, Vector3.new(0, -config.Gravity, 0), duration, steps)
end

---Where the arc crosses a horizontal plane, e.g. the floor.
function Projectiles.landing(origin, direction)
	local config = Projectiles.current
	local velocity = direction.Unit * config.Speed
	return Math2.arcLanding(origin, velocity, Vector3.new(0, -config.Gravity, 0), 0)
end

-- ==========================================================================
-- Drawing
-- ==========================================================================

local trailFolder = nil

---Draw the arc as thin parts. Returns the count drawn.
function Projectiles.trail(origin, direction, points)
	Projectiles.clearTrail()
	local layer = workspace.CurrentCamera
	if not layer then
		return 0
	end
	local folder = Instance.new("Folder")
	folder.Name = "FatCatTrail"
	folder.Parent = layer
	trailFolder = folder

	points = points or Projectiles.arc(origin, direction)
	local drawn = 0
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(94, 194, 255)
		part.Size = Vector3.new(0.06, 0.06, (b - a).Magnitude)
		part.CFrame = CFrame.lookAt(a, b)
		part.Parent = folder
		drawn += 1
	end
	return drawn
end

function Projectiles.clearTrail()
	if trailFolder then
		trailFolder:Destroy()
		trailFolder = nil
	end
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Projectile config", 1)
	local config = Projectiles.current
	local speedField = Materials.Input(section.frame, {
		Text = "Speed (studs/s)",
		Default = tostring(config.Speed),
		OnSubmit = function(value)
			Projectiles.set({ Speed = tonumber(value) or config.Speed, Gravity = config.Gravity })
		end,
	})
	local gravityField = Materials.Input(section.frame, {
		Text = "Gravity",
		Default = tostring(config.Gravity),
		OnSubmit = function(value)
			Projectiles.set({ Speed = config.Speed, Gravity = tonumber(value) or config.Gravity })
		end,
	})
	Materials.Button(section.frame, {
		Text = "Use workspace gravity",
		OnClick = function()
			local values = Projectiles.useEngineGravity()
			gravityField:Set(values.Gravity)
		end,
	})

	local scanSection = page:Section("Found in scripts", 2)
	local scanOutput = Materials.Code(scanSection.frame, { Height = 260 })
	Materials.Button(scanSection.frame, {
		Text = "Scan loaded scripts",
		OnClick = function()
			local candidates, reason = Projectiles.scan()
			if #candidates == 0 then
				scanOutput:SetLines({ reason or "No projectile tables found. Set the values above." })
				return
			end
			local lines = {}
			for index, candidate in candidates do
				local entry = ("%d) Speed=%s (%s)  Gravity=%s (%s)"):format(
					index, tostring(candidate.speed), candidate.speedKey,
					tostring(candidate.gravity), candidate.gravityKey)
				table.insert(lines, entry)
				-- Clicking a candidate is out of scope for a code view; the
				-- first scan result can be applied with the button below.
			end
			scanOutput:SetLines(lines, 200)
			Projectiles._lastScan = candidates
		end,
	})
	Materials.Button(scanSection.frame, {
		Text = "Apply first match",
		OnClick = function()
			local candidates = Projectiles._lastScan
			if not candidates or #candidates == 0 then
				return
			end
			local first = candidates[1]
			Projectiles.set({ Speed = first.speed, Gravity = first.gravity })
			speedField:Set(first.speed)
			gravityField:Set(first.gravity)
		end,
	})

	Core:OnDestroy("projectiles:trail", Projectiles.clearTrail)
	return { speedField = speedField, gravityField = gravityField }
end

Projectiles.mount = mount

return function(core, mathModule, materials)
	Core = core
	Math2 = mathModule
	Materials = materials
	return Projectiles
end

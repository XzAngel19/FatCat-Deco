-- Fat Cat Project | Utilities, Console & Math/FatCatMath.lua
--
-- Vectors, world-to-screen, prediction and trajectories. No state, no
-- instances, no globals: every function takes its inputs and returns a value,
-- which is why this is the one module the tests can hammer without a mock.
--
--   local Math = FatCat.require("FatCatMath")
--   local point, onScreen = Math.worldToScreen(camera, position)
--   local lead = Math.predict(targetPosition, targetVelocity, projectileSpeed)
--
-- Coordinate conventions used everywhere below:
--   * positions are Vector3 in world space, studs;
--   * the camera looks down -Z in its own space (Roblox convention);
--   * a point behind the camera is never projected: the divide by Z would
--     flip it to the wrong side of the screen. `onScreen` is false instead.

local Math2
Math2 = {}

-- ==========================================================================
-- Scalars and vectors
-- ==========================================================================

function Math2.clamp(value, low, high)
	return math.clamp(value, low, high)
end

---Linear interpolation, unclamped t (extrapolation is legal).
function Math2.lerp(from, to, t)
	return from + (to - from) * t
end

---Map `value` from one range to another, clamped to the output range.
function Math2.remap(value, inMin, inMax, outMin, outMax)
	if inMax == inMin then
		return outMin
	end
	local t = math.clamp((value - inMin) / (inMax - inMin), 0, 1)
	return outMin + (outMax - outMin) * t
end

---Length of a Vector3, tolerant of a nil input (0).
function Math2.length(vector)
	if not vector then
		return 0
	end
	return vector.Magnitude
end

---Unit vector, or a zero vector when the input has no length.
function Math2.normalize(vector)
	if not vector then
		return Vector3.zero
	end
	local magnitude = vector.Magnitude
	if magnitude < 1e-6 then
		return Vector3.zero
	end
	return vector / magnitude
end

---Horizontal (XZ) distance. Height differences should not make a ground
---check read as "far away".
function Math2.flatDistance(a, b)
	if not (a and b) then
		return math.huge
	end
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function Math2.distance(a, b)
	if not (a and b) then
		return math.huge
	end
	return (a - b).Magnitude
end

---Dot product of two Vector3, 0 when either is missing.
function Math2.dot(a, b)
	if not (a and b) then
		return 0
	end
	return a:Dot(b)
end

---Angle between two vectors in degrees, 0 when either is degenerate.
function Math2.angleBetween(a, b)
	local ua, ub = Math2.normalize(a), Math2.normalize(b)
	if ua == Vector3.zero or ub == Vector3.zero then
		return 0
	end
	return math.deg(math.acos(math.clamp(ua:Dot(ub), -1, 1)))
end

-- ==========================================================================
-- World to screen
-- ==========================================================================
-- Returns screenX, screenY, onScreen, depth. Screen coordinates are pixels in
-- the camera's viewport; a caller drawing a 2D overlay can use them directly.

---Project a world position through `camera`.
function Math2.worldToScreen(camera, position)
	if not camera or not position then
		return 0, 0, false, 0
	end

	local viewport = camera.ViewportSize
	if not viewport or viewport.X <= 0 or viewport.Y <= 0 then
		return 0, 0, false, 0
	end

	local relative = camera.CFrame:PointToObjectSpace(position)
	-- Behind (or exactly on) the near plane: no valid projection exists.
	if relative.Z > -0.01 then
		return 0, 0, false, relative.Z
	end

	local focal = viewport.Y / 2
	local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
	if tanHalf <= 0 then
		return 0, 0, false, relative.Z
	end
	focal = focal / tanHalf

	local x = viewport.X / 2 + (relative.X / -relative.Z) * focal
	local y = viewport.Y / 2 + (-relative.Y / -relative.Z) * focal

	local onScreen = x >= 0 and y >= 0 and x <= viewport.X and y <= viewport.Y
	return x, y, onScreen, -relative.Z
end

---Screen-space size of a world-space sphere, in pixels. Used by the ESP to
---keep boxes proportional at range instead of drawing a fixed rectangle.
function Math2.worldToScreenSize(camera, position, worldRadius)
	local _, _, _, depth = Math2.worldToScreen(camera, position)
	if depth <= 0 then
		return 0
	end
	local viewport = camera.ViewportSize
	local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
	if tanHalf <= 0 then
		return 0
	end
	return (worldRadius * 2 * (viewport.Y / 2)) / (depth * tanHalf)
end

---True when `point` is inside the camera frustum, with a margin in pixels.
function Math2.inView(camera, point, margin)
	if not (camera and point) then
		return false
	end
	local x, y, _, depth = Math2.worldToScreen(camera, point)
	if depth <= 0 then
		return false
	end
	local viewport = camera.ViewportSize
	local pad = margin or 0
	return x >= -pad and y >= -pad and x <= viewport.X + pad and y <= viewport.Y + pad
end

-- ==========================================================================
-- Prediction
-- ==========================================================================
-- The projectile problem: by the time a bullet reaches the target, the target
-- has moved. Given a muzzle position, a target position and velocity, and a
-- projectile speed, solve for the lead point.
--
-- This is the closed-form solution for constant target velocity and constant
-- projectile speed (a quadratic in time). It is correct for the common case
-- (a game with gravity-less or fast projectiles) and it degrades sanely when
-- there is no solution: a target that outruns the projectile returns nil,
-- which the caller must handle rather than silently aiming behind.

---Lead point, or nil when the projectile can never catch the target.
---@param muzzle Vector3
---@param target Vector3
---@param velocity Vector3
---@param speed number        studs per second
function Math2.predict(muzzle, target, velocity, speed)
	if not (muzzle and target and velocity) then
		return nil
	end
	speed = tonumber(speed) or 0
	if speed <= 0 then
		return nil
	end

	local offset = target - muzzle
	local a = velocity:Dot(velocity) - speed * speed
	local b = 2 * offset:Dot(velocity)
	local c = offset:Dot(offset)

	local function leadAt(t)
		return target + velocity * t
	end

	-- a ~ 0: the target moves at exactly projectile speed, linear equation.
	if math.abs(a) < 1e-6 then
		if math.abs(b) < 1e-6 then
			return nil
		end
		local t = -c / b
		if t < 0 then
			return nil
		end
		return leadAt(t)
	end

	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil
	end
	local root = math.sqrt(discriminant)
	local t1 = (-b + root) / (2 * a)
	local t2 = (-b - root) / (2 * a)

	-- Two roots: the earlier positive one is the first intercept.
	local t = nil
	if t1 > 0 and t2 > 0 then
		t = math.min(t1, t2)
	elseif t1 > 0 then
		t = t1
	elseif t2 > 0 then
		t = t2
	end
	if not t then
		return nil
	end
	return leadAt(t)
end

---Same as predict, but returns the flight time too.
function Math2.timeToImpact(muzzle, target, speed)
	if not (muzzle and target) then
		return nil
	end
	speed = tonumber(speed) or 0
	if speed <= 0 then
		return nil
	end
	return (target - muzzle).Magnitude / speed
end

-- ==========================================================================
-- Trajectories
-- ==========================================================================
-- Points along an arc, for drawing a grenade path or a prediction rail. The
-- arc is a parabola in world space with an explicit gravity constant, so a
-- game that uses different gravity can pass its own.

function Math2.arc(origin, velocity, gravity, duration, steps)
	gravity = gravity or Vector3.new(0, -workspace.Gravity, 0)
	duration = duration or 1
	steps = math.max(steps or 16, 2)
	local points = {}
	for index = 0, steps do
		local t = duration * (index / steps)
		points[index + 1] = origin + velocity * t + gravity * (0.5 * t * t)
	end
	return points
end

---Where the arc lands on a plane at `height`.
function Math2.arcLanding(origin, velocity, gravity, height)
	gravity = gravity or Vector3.new(0, -workspace.Gravity, 0)
	height = height or 0
	local rise = origin.Y - height
	-- rise + vy*t + 0.5*gy*t^2 = 0, solve for the positive root.
	local a = 0.5 * gravity.Y
	local b = velocity.Y
	local c = rise
	if math.abs(a) < 1e-6 then
		if math.abs(b) < 1e-6 then
			return nil
		end
		local t = -c / b
		if t < 0 then
			return nil
		end
		return origin + velocity * t + gravity * (0.5 * t * t), t
	end
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil
	end
	local root = math.sqrt(discriminant)
	local t1 = (-b + root) / (2 * a)
	local t2 = (-b - root) / (2 * a)
	local t = (t1 > 0 and t2 > 0) and math.min(t1, t2) or math.max(t1, t2)
	if t < 0 then
		return nil
	end
	return origin + Vector3.new(velocity.X * t, velocity.Y * t + 0.5 * gravity.Y * t * t, velocity.Z * t), t
end

-- ==========================================================================
-- Angles and directions
-- ==========================================================================

---Unit direction vector from Euler angles in degrees, Roblox look convention.
function Math2.directionFromAngles(pitch, yaw)
	local p = math.rad(pitch or 0)
	local y = math.rad(yaw or 0)
	return Vector3.new(
		-math.sin(y) * math.cos(p),
		math.sin(p),
		-math.cos(y) * math.cos(p)
	)
end

---Aim at `target` from `origin`, as (pitch, yaw) in degrees.
function Math2.anglesTo(origin, target)
	if not (origin and target) then
		return 0, 0
	end
	local delta = target - origin
	local yaw = math.deg(math.atan2(-delta.X, -delta.Z))
	local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	local pitch = math.deg(math.atan2(delta.Y, flat))
	return pitch, yaw
end

---Normalise an angle to (-180, 180].
function Math2.wrapAngle(degrees)
	degrees = degrees % 360
	if degrees > 180 then
		degrees -= 360
	end
	return degrees
end

return function(_core)
	return Math2
end

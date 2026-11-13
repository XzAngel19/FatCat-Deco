-- Fat Cat Project | Utilities, Console & Math/FatCatUniversal.lua
--
-- The movement/visual utilities that work in any game: ESP, fly, noclip,
-- fullbright, walk speed, jump power, teleport. "Universal" means exactly
-- that: nothing here reads a game-specific remote or offset.
--
--   local U = FatCat.require("FatCatUniversal")
--   U.esp(true)                  -- boxes + names on every player
--   U.fly(true)                  -- free camera-relative flight
--   U.noclip(true)               -- through walls, until turned off
--   U.unload()                   -- restore walkspeed/jump/camera, drop ESP
--
-- Every feature here is reversible and registers its own restore with Core,
-- so `FatCatEnv.unload()` puts the character back the way it was: a script
-- that leaves a player at walkspeed 500 after "unloading" is worse than one
-- that never ran.
--
-- What this module deliberately does NOT do:
--   * no anti-cheat evasion, no detection-string removal, no hooking;
--   * no per-game exploits (that is what the analysis modules are for);
--   * nothing that writes to another player's character.
-- If a game forbids what these do, that is a server rule, not a technical
-- problem this file can solve.

local Core, Design, U
U = {}

local player = game:GetService("Players").LocalPlayer
local runService = game:GetService("RunService")
local userInput = game:GetService("UserInputService")

-- Original values, captured the first time a feature changes them.
local originals = {
	walkSpeed = nil,
	jumpPower = nil,
	jumpHeight = nil,
	hipHeight = nil,
	gravity = nil,
	lighting = nil,
}
local espFolder = nil
local espCache = {}
local flyState = nil
local noclipOn = false

local function character()
	local char = player and player.Character
	if not char then
		return nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	return char, humanoid
end

local function rootPart(char)
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
end

-- ==========================================================================
-- Walk speed / jump
-- ==========================================================================

---Set walkspeed, remembering the original once so unload can restore it.
function U.walkSpeed(speed)
	local _, humanoid = character()
	if not humanoid then
		return false, "no character yet"
	end
	speed = math.clamp(tonumber(speed) or 16, 0, 1000)
	if originals.walkSpeed == nil then
		originals.walkSpeed = humanoid.WalkSpeed
		Core:OnDestroy("universal:walkSpeed", function()
			if humanoid.Parent then
				humanoid.WalkSpeed = originals.walkSpeed
			end
		end)
	end
	humanoid.WalkSpeed = speed
	return true, speed
end

---Set jump power (classic) or jump height (newer games), whichever the
---humanoid is configured to use.
function U.jumpPower(power)
	local _, humanoid = character()
	if not humanoid then
		return false, "no character yet"
	end
	power = math.clamp(tonumber(power) or 50, 0, 1000)
	if humanoid.UseJumpPower then
		if originals.jumpPower == nil then
			originals.jumpPower = humanoid.JumpPower
			Core:OnDestroy("universal:jumpPower", function()
				if humanoid.Parent then
					humanoid.JumpPower = originals.jumpPower
				end
			end)
		end
		humanoid.JumpPower = power
	else
		if originals.jumpHeight == nil then
			originals.jumpHeight = humanoid.JumpHeight
			Core:OnDestroy("universal:jumpHeight", function()
				if humanoid.Parent then
					humanoid.JumpHeight = originals.jumpHeight
				end
			end)
		end
		humanoid.JumpHeight = power
	end
	return true, power
end

-- ==========================================================================
-- Noclip
-- ==========================================================================
-- Noclip works by clearing CanCollide on every BasePart of the character each
-- frame. The alternative (writing to the part's `CanCollide` only once) fails
-- because the character controller re-enables collision on respawn and on
-- every state change, so this has to be a per-frame pass.
local noclipConnection = nil

function U.noclip(on)
	on = on and true or false
	if on == noclipOn then
		return true, on
	end
	noclipOn = on

	if on then
		local link = runService.Stepped:Connect(function()
			local char = character()
			if not char then
				return
			end
			for _, part in char:GetDescendants() do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end)
		noclipConnection = link
		Core:OnDestroy("universal:noclip", function()
			if link then
				link:Disconnect()
			end
			noclipOn = false
		end)
	else
		if noclipConnection then
			noclipConnection:Disconnect()
			noclipConnection = nil
		end
		local char = character()
		if char then
			for _, part in char:GetDescendants() do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					part.CanCollide = true
				end
			end
		end
	end
	return true, on
end

-- ==========================================================================
-- Fly
-- ==========================================================================
-- Free flight: a BodyVelocity on the root part, driven toward the movement
-- vector the player is holding, with Space/Ctrl for vertical. The camera is
-- left alone; the character follows the camera's yaw.
--
-- Turning it off removes the velocity, restores PlatformStand (some games
-- freeze you in the air with it on), and gives the character a moment of
-- zero gravity so it falls instead of hovering.

function U.fly(on, speed)
	on = on and true or false
	speed = tonumber(speed) or 60

	if not on then
		if flyState then
			if flyState.velocity then
				flyState.velocity:Destroy()
			end
			if flyState.connection then
				flyState.connection:Disconnect()
			end
			local _, humanoid = character()
			if humanoid then
				humanoid.PlatformStand = false
			end
			flyState = nil
		end
		return true, false
	end

	if flyState then
		-- Already flying: change the speed without rebuilding the body mover.
		flyState.speed = speed
		return true, true
	end

	local char, humanoid = character()
	local root = rootPart(char)
	if not (root and humanoid) then
		return false, "no character yet"
	end

	humanoid.PlatformStand = true
	local body = Instance.new("BodyVelocity")
	body.Name = "FatCatFly"
	body.Velocity = Vector3.zero
	body.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	body.Parent = root

	local state = { velocity = body, speed = speed, connection = nil }
	flyState = state

	state.connection = runService.RenderStepped:Connect(function()
		local currentChar = player and player.Character
		local currentRoot = currentChar and currentChar:FindFirstChild("HumanoidRootPart")
		if not currentRoot or not body.Parent then
			return
		end

		local camera = workspace.CurrentCamera
		local direction = Vector3.zero
		if userInput:IsKeyDown(Enum.KeyCode.W) then
			direction += camera.CFrame.LookVector
		end
		if userInput:IsKeyDown(Enum.KeyCode.S) then
			direction -= camera.CFrame.LookVector
		end
		if userInput:IsKeyDown(Enum.KeyCode.D) then
			direction += camera.CFrame.RightVector
		end
		if userInput:IsKeyDown(Enum.KeyCode.A) then
			direction -= camera.CFrame.RightVector
		end
		if userInput:IsKeyDown(Enum.KeyCode.Space) then
			direction += Vector3.yAxis
		end
		if userInput:IsKeyDown(Enum.KeyCode.LeftControl) then
			direction -= Vector3.yAxis
		end

		if direction.Magnitude > 0 then
			body.Velocity = direction.Unit * state.speed
		else
			body.Velocity = Vector3.zero
		end
	end)

	Core:OnDestroy("universal:fly", function()
		if state.velocity then
			state.velocity:Destroy()
		end
		if state.connection then
			state.connection:Disconnect()
		end
		local _, currentHumanoid = character()
		if currentHumanoid then
			currentHumanoid.PlatformStand = false
		end
	end)
	return true, true
end

-- ==========================================================================
-- ESP
-- ==========================================================================
-- One BillboardGui per player, parented to a folder in CoreGui so a single
-- Destroy removes the whole thing. Boxes use the model's bounding box, so a
-- crouching player gets a shorter box without any extra code.

local function coreGui()
	local ok, container = pcall(function()
		return game:GetService("CoreGui")
	end)
	return ok and container or nil
end

local function clearEsp()
	if espFolder then
		espFolder:Destroy()
		espFolder = nil
	end
	table.clear(espCache)
end

local function styleFor(player)
	-- Colour by team when the game has teams; otherwise one accent. This is
	-- the one place a colour is hardcoded, and it is the palette's accent.
	local color = Design.color("accent")
	local success, teamColor = pcall(function()
		return player.TeamColor.Color
	end)
	if success and teamColor then
		color = teamColor
	end
	return color
end

local function addHighlight(target)
	if espCache[target] then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "FatCatESP"
	highlight.FillColor = styleFor(target)
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.72
	highlight.OutlineTransparency = 0.25
	highlight.Adornee = target.Character
	highlight.Parent = espFolder
	espCache[target] = highlight
end

local function refreshEsp()
	if not espFolder then
		return
	end
	local ok, players = pcall(function()
		return game:GetService("Players"):GetPlayers()
	end)
	if not ok or type(players) ~= "table" then
		return
	end
	for _, other in players do
		if other == player then
			continue
		end
		if other.Character then
			addHighlight(other)
		elseif espCache[other] then
			espCache[other]:Destroy()
			espCache[other] = nil
		end
	end
end

function U.esp(on)
	on = on and true or false
	if not on then
		clearEsp()
		return true, false
	end

	local container = coreGui()
	if not container then
		return false, "CoreGui is not accessible on this executor"
	end

	clearEsp()
	local folder = Instance.new("Folder")
	folder.Name = "FatCatESP"
	folder.Parent = container
	espFolder = folder

	refreshEsp()

	local join = game:GetService("Players").PlayerAdded:Connect(function()
		refreshEsp()
	end)
	local leave = game:GetService("Players").PlayerRemoving:Connect(function(other)
		if espCache[other] then
			espCache[other]:Destroy()
			espCache[other] = nil
		end
	end)

	Core:OnDestroy("universal:esp", function()
		join:Disconnect()
		leave:Disconnect()
		clearEsp()
	end)
	return true, true
end

-- ==========================================================================
-- Lighting and teleport
-- ==========================================================================

---Fullbright: remove ambient occlusion and fog so a dark map is readable.
---Restores the exact original Lighting properties on unload.
function U.fullbright(on)
	local lighting = game:GetService("Lighting")
	if originals.lighting == nil then
		originals.lighting = {
			Ambient = lighting.Ambient,
			OutdoorAmbient = lighting.OutdoorAmbient,
			FogEnd = lighting.FogEnd,
			Brightness = lighting.Brightness,
			ClockTime = lighting.ClockTime,
		}
		Core:OnDestroy("universal:lighting", function()
			local saved = originals.lighting
			if saved then
				lighting.Ambient = saved.Ambient
				lighting.OutdoorAmbient = saved.OutdoorAmbient
				lighting.FogEnd = saved.FogEnd
				lighting.Brightness = saved.Brightness
				lighting.ClockTime = saved.ClockTime
			end
		end)
	end

	if on then
		lighting.Ambient = Color3.new(1, 1, 1)
		lighting.OutdoorAmbient = Color3.new(1, 1, 1)
		lighting.Brightness = 2
		lighting.FogEnd = 1e6
		lighting.ClockTime = 14
	else
		local saved = originals.lighting
		lighting.Ambient = saved.Ambient
		lighting.OutdoorAmbient = saved.OutdoorAmbient
		lighting.Brightness = saved.Brightness
		lighting.FogEnd = saved.FogEnd
		lighting.ClockTime = saved.ClockTime
	end
	return true, on
end

---Move the character to a position. Returns false with a reason when there is
---no character; a nil Y keeps the current height.
function U.teleport(position)
	local char = character()
	local root = rootPart(char)
	if not root or not position then
		return false, "no character yet"
	end
	local target = Vector3.new(position.X, position.Y or root.Position.Y, position.Z)
	root.CFrame = CFrame.new(target)
	return true, target
end

---Teleport to another player, offset so the two do not overlap.
function U.teleportToPlayer(name)
	local players = game:GetService("Players")
	local found = players:FindFirstChild(name)
	if not found then
		return false, ("no player named '%s'"):format(tostring(name))
	end
	local char = found.Character
	local root = rootPart(char)
	if not root then
		return false, "that player has no character"
	end
	return U.teleport(root.Position + Vector3.new(0, 0, 3))
end

---Recharge the humanoid's health. Works on client-side humanoids only, which
---is the only place a client script can write to.
function U.heal()
	local _, humanoid = character()
	if not humanoid then
		return false, "no character yet"
	end
	humanoid.Health = humanoid.MaxHealth
	return true, humanoid.Health
end

---Take the camera off the character (free cam) or give it back.
function U.freeCam(on)
	local camera = workspace.CurrentCamera
	if not camera then
		return false, "no camera"
	end
	if on then
		camera.CameraType = Enum.CameraType.Scriptable
	else
		camera.CameraType = Enum.CameraType.Custom
	end
	return true, camera.CameraType
end

---Restore everything this module touched. Called by FatCatEnv.unload via the
---teardowns registered above, but exposed so the Utilities tab can offer it.
function U.restore()
	U.fly(false)
	U.noclip(false)
	U.esp(false)
end

return function(core, design, _signal, _mathModule)
	Core = core
	Design = design
	return U
end

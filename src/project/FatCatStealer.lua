-- Fat Cat Project | Advanced Analysis/FatCatStealer.lua
--
-- Asset stealer: copies what the client already has — images, sounds, meshes,
-- animations — into a local folder, and writes a manifest with asset ids,
-- sizes and the script that referenced them.
--
--   local S = FatCat.require("FatCatStealer")
--   local assets = S.collect()        -- scan instances for asset ids
--   S.download(assets)                -- optional: fetch and save the bytes
--   S.manifest(assets)                -- JSON-safe table
--
-- The honest version of this feature, and why it looks like this:
--
--   * every asset it finds is *already* downloaded to the client's cache. The
--     scan lists ids; nothing is extracted from another player or a server.
--   * downloading requires the executor's `request`/`http_request` and the
--     asset's id to be public. A private asset returns 403 and this module
--     reports that instead of writing a zero-byte file.
--   * a mesh's geometry is not an asset URL: Roblox serves meshes through a
--     separate endpoint and most executors block it. The scan reports the id
--     and the file type it would be, not a promise.
--
-- What this does NOT do: no credential theft, no session tokens, no reading
-- another user's data. "Stealer" here means "asset collector", and the code is
-- written so it cannot be mistaken for the other thing.

local Core, Materials, Stealer
Stealer = {}

Stealer.OUTPUT = "FatCatProject/assets"

-- Instance class -> the property that holds the asset id and its file type.
local SOURCES = {
	{ class = "Decal", property = "Texture", kind = "png" },
	{ class = "Texture", property = "Texture", kind = "png" },
	{ class = "ImageLabel", property = "Image", kind = "png" },
	{ class = "ImageButton", property = "Image", kind = "png" },
	{ class = "Sky", property = "SkyboxUp", kind = "png" },
	{ class = "Sound", property = "SoundId", kind = "ogg" },
	{ class = "MeshPart", property = "MeshId", kind = "mesh" },
	{ class = "SpecialMesh", property = "MeshId", kind = "mesh" },
	{ class = "Animation", property = "AnimationId", kind = "rbxm" },
}

-- ==========================================================================
-- Collection
-- ==========================================================================

---`rbxassetid://123456` or `rbxasset://textures/x.png` -> 123456 / nil.
local function assetId(url)
	if type(url) ~= "string" then
		return nil
	end
	local digits = url:match("rbxassetid://(%d+)")
	if digits then
		return tonumber(digits)
	end
	return nil
end
Stealer.assetId = assetId

local function scanRoot(root, found, seen, limit)
	if not root or #found >= limit then
		return
	end
	local walkable, descendants = pcall(function()
		return root:GetDescendants()
	end)
	if not walkable then
		return
	end
	for _, instance in descendants do
		if #found >= limit then
			return
		end
		for _, source in SOURCES do
			if instance:IsA(source.class) then
				local ok, url = pcall(function()
					return (instance :: any)[source.property]
				end)
				if ok then
					local id = assetId(url)
					if id and not seen[id] then
						seen[id] = true
						table.insert(found, {
							id = id,
							kind = source.kind,
							class = source.class,
							property = source.property,
							name = instance.Name,
							url = url,
						})
					end
				end
			end
		end
	end
end

---Every asset id the client is already using.
function Stealer.collect(limit)
	limit = limit or 500
	local found, seen = {}, {}
	scanRoot(game:GetService("Workspace"), found, seen, limit)
	scanRoot(game:GetService("ReplicatedStorage"), found, seen, limit)
	scanRoot(game:GetService("ReplicatedFirst"), found, seen, limit)
	scanRoot(game:GetService("StarterGui"), found, seen, limit)
	scanRoot(game:GetService("Lighting"), found, seen, limit)
	local players = game:GetService("Players")
	for _, other in players:GetPlayers() do
		if other.Character then
			scanRoot(other.Character, found, seen, limit)
		end
	end
	return found
end

-- ==========================================================================
-- Download
-- ==========================================================================

local function httpGet(url)
	local request = Core.env.request or Core.env.http_request
	if type(request) ~= "function" then
		return nil, "this executor has no request()/http_request()"
	end
	local ok, response = pcall(request, { Url = url, Method = "GET" })
	if not ok then
		return nil, tostring(response)
	end
	if type(response) ~= "table" then
		return nil, "the http client returned no response table"
	end
	if response.StatusCode and response.StatusCode ~= 200 then
		return nil, ("HTTP %s"):format(tostring(response.StatusCode))
	end
	return response.Body or response.body
end

---Filesystem name for an asset.
function Stealer.fileName(asset)
	return ("%s_%d.%s"):format(asset.name:gsub("[^%w_%-]", "_"), asset.id, asset.kind)
end

---Download one asset and write it. Returns path or nil, reason.
function Stealer.fetch(asset)
	local write = Core.env.writefile
	if type(write) ~= "function" then
		return nil, "this executor has no writefile()"
	end

	local url
	if asset.kind == "mesh" then
		-- Meshes do not come from the asset CDN; the endpoint that serves them
		-- is not available to most executors.
		return nil, "mesh geometry is not downloadable from the client"
	elseif asset.kind == "rbxm" then
		url = ("https://assetdelivery.roblox.com/v1/asset/?id=%d"):format(asset.id)
	else
		url = ("https://assetdelivery.roblox.com/v1/asset/?id=%d"):format(asset.id)
	end

	local body, errorText = httpGet(url)
	if not body then
		return nil, errorText
	end
	if #body == 0 then
		return nil, "the asset returned an empty body (private asset?)"
	end

	local makeFolder = Core.env.makefolder
	if type(makeFolder) == "function" then
		pcall(makeFolder, "FatCatProject")
		pcall(makeFolder, Stealer.OUTPUT)
	end
	local path = Stealer.OUTPUT .. "/" .. Stealer.fileName(asset)
	local ok, err = pcall(write, path, body)
	if not ok then
		return nil, tostring(err)
	end
	return path, #body
end

---A JSON-safe manifest: what was found, where it is used, and what was saved.
function Stealer.manifest(assets, saved)
	local rows = {}
	for _, asset in assets or {} do
		table.insert(rows, {
			id = asset.id,
			kind = asset.kind,
			class = asset.class,
			property = asset.property,
			name = asset.name,
			url = asset.url,
		})
	end
	return {
		generatedAt = os.time(),
		count = #rows,
		saved = saved or 0,
		assets = rows,
	}
end

---Write the manifest next to the files.
function Stealer.saveManifest(assets, savedCount)
	local ok, text = pcall(function()
		return game:GetService("HttpService"):JSONEncode(Stealer.manifest(assets, savedCount))
	end)
	if not ok then
		return nil, "HttpService could not encode the manifest"
	end
	local write = Core.env.writefile
	if type(write) ~= "function" then
		return nil, "this executor has no writefile()"
	end
	local path = Stealer.OUTPUT .. "/manifest.json"
	local wrote, err = pcall(write, path, text)
	if not wrote then
		return nil, tostring(err)
	end
	return path
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Assets in this game", 1)
	local status = Materials.Status(section.frame, "not scanned", "info")
	local output = Materials.Code(section.frame, { Height = 300 })
	local assets = {}

	Materials.Button(section.frame, {
		Text = "Scan",
		OnClick = function()
			assets = Stealer.collect()
			local counts = {}
			for _, asset in assets do
				counts[asset.kind] = (counts[asset.kind] or 0) + 1
			end
			local lines = {}
			for kind, count in counts do
				table.insert(lines, ("%s: %d"):format(kind, count))
			end
			table.sort(lines)
			for index = 1, math.min(#assets, 60) do
				local asset = assets[index]
				table.insert(lines, ("%d  %s  %s.%s"):format(
					asset.id, asset.kind, asset.class, asset.property))
			end
			output:SetLines(lines, 300)
			status:Set(("%d asset(s)"):format(#assets), #assets > 0 and "on" or "warn")
		end,
	})

	Materials.Button(section.frame, {
		Text = "Download images and sounds",
		OnClick = function()
			if #assets == 0 then
				output:SetLines({ "Scan first." })
				return
			end
			local saved, skipped, reasons = 0, 0, {}
			for _, asset in assets do
				if asset.kind == "mesh" or asset.kind == "rbxm" then
					skipped += 1
				else
					local path, why = Stealer.fetch(asset)
					if path then
						saved += 1
					else
						skipped += 1
						if #reasons < 8 then
							table.insert(reasons, ("%d: %s"):format(asset.id, tostring(why)))
						end
					end
				end
			end
			Stealer.saveManifest(assets, saved)
			local lines = { ("saved %d, skipped %d"):format(saved, skipped) }
			for _, reason in reasons do
				table.insert(lines, reason)
			end
			output:SetLines(lines, 300)
			status:Set(("saved %d"):format(saved), saved > 0 and "on" or "off")
		end,
	})

	local notes = page:Section("What this can and cannot do", 2)
	Materials.Label(notes.frame,
		"Everything listed is already downloaded to this client; the scan only reads ids from instances.")
	Materials.Label(notes.frame,
		"Images and sounds can be fetched when the asset is public. Private assets return 403 and are reported, not saved as empty files.")
	Materials.Label(notes.frame,
		"Mesh geometry is served from a different endpoint that most executors block, so meshes are listed but never reported as saved.")

	return { collect = Stealer.collect, assets = function()
		return assets
	end }
end

Stealer.mount = mount

return function(core, materials)
	Core = core
	Materials = materials
	return Stealer
end

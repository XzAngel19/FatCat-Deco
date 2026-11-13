-- Fat Cat Project | Core & Initialization/FatCatConfig.lua
--
-- Presets on disk. One JSON file per preset, one index that remembers the
-- order they were created in and which one is active.
--
--   FatCatProject/
--   └── presets/
--       ├── index.json      { order = {"raid","default"}, active = "raid" }
--       ├── raid.json       { "aim.fov" = 90, "visual.esp" = true, ... }
--       └── default.json
--
-- The executor filesystem is optional and inconsistent: `writefile` may not
-- exist at all, `isfile` may lie, and `makefolder` on an existing folder may
-- throw. Every call goes through a guard, so a missing function becomes a
-- sentence the user can read on the Settings tab instead of an error deep in
-- a button callback.

local Core, Signal, Config
Config = {}

Config.FOLDER = "FatCatProject"
Config.PRESET_DIR = "FatCatProject/presets"
Config.INDEX = "FatCatProject/presets/index.json"

-- Executor globals, not Roblox ones, so the analyzer must not assume they
-- exist. Read lazily through Core.env: this module body runs when the bundle
-- is *built*, long before FatCatInit constructs the module and hands it the
-- core, so `local env = Core.env` here would capture nil and every file call
-- would fail with "attempt to index nil". Nothing at this level may read Core.
local function env()
	return Core.env
end

local function fn(name)
	local value = env()[name]
	if type(value) ~= "function" then
		return nil
	end
	return value
end

---Call an executor file function; returns ok, result.
local function call(name, ...)
	local impl = fn(name)
	if not impl then
		return false, ("this executor has no %s()"):format(name)
	end
	local ok, result = pcall(impl, ...)
	if not ok then
		return false, tostring(result)
	end
	return true, result
end

---True when the executor can read and write files at all.
function Config:Available()
	return fn("writefile") ~= nil and fn("readfile") ~= nil
end

---A sentence for the UI when saving is impossible.
function Config:UnavailableReason()
	if fn("writefile") == nil and fn("readfile") == nil then
		return "this executor exposes neither writefile nor readfile"
	elseif fn("writefile") == nil then
		return "this executor cannot write files"
	end
	return "this executor cannot read files"
end

local function ensureFolder(path)
	local ok, reason = call("makefolder", path)
	if ok then
		return true
	end
	-- "folder already exists" is success for our purposes; anything else is
	-- only a problem if writing actually fails later.
	if tostring(reason):lower():find("exist", 1, true) then
		return true
	end
	return false, reason
end

-- ==========================================================================
-- JSON
-- ==========================================================================
-- HttpService is the normal path. Some executors block it on the client, and
-- a few expose the executor's own HttpService table; both are tried before
-- giving up, because a preset that silently refuses to save is worse than a
-- slower save.

local function httpService()
	local ok, service = pcall(function()
		return game:GetService("HttpService")
	end)
	if ok then
		return service
	end
	return nil
end

local function encode(value)
	local http = httpService()
	if http then
		local ok, text = pcall(function()
			return http:JSONEncode(value)
		end)
		if ok and type(text) == "string" then
			return text
		end
	end
	local executor = env().HttpService
	if type(executor) == "table" and type(executor.JSONEncode) == "function" then
		local ok, text = pcall(executor.JSONEncode, value)
		if ok and type(text) == "string" then
			return text
		end
	end
	return nil, "JSON could not be encoded (HttpService is unavailable)"
end

local function decode(text)
	local http = httpService()
	if http then
		local ok, value = pcall(function()
			return http:JSONDecode(text)
		end)
		if ok then
			return value
		end
	end
	local executor = env().HttpService
	if type(executor) == "table" and type(executor.JSONDecode) == "function" then
		local ok, value = pcall(executor.JSONDecode, text)
		if ok then
			return value
		end
	end
	return nil, "the file is not valid JSON"
end

-- ==========================================================================
-- Files
-- ==========================================================================

---Read one JSON file. Returns value, or nil plus a reason.
function Config:ReadJSON(path)
	if not self:Available() then
		return nil, self:UnavailableReason()
	end

	local isFile = fn("isfile")
	if isFile then
		local ok, exists = pcall(isFile, path)
		if not ok then
			return nil, ("isfile('%s') failed: %s"):format(path, tostring(exists))
		end
		if not exists then
			return nil, "no file at " .. path
		end
	end

	local ok, text = call("readfile", path)
	if not ok then
		return nil, tostring(text)
	end
	if type(text) ~= "string" or text == "" then
		return nil, path .. " is empty"
	end
	return decode(text)
end

---Write one JSON file. Returns true, or false plus a reason.
function Config:WriteJSON(path, value)
	if not self:Available() then
		return false, self:UnavailableReason()
	end
	ensureFolder(self.FOLDER)
	ensureFolder(self.PRESET_DIR)

	local text, encodeError = encode(value)
	if not text then
		return false, encodeError
	end
	local ok, writeError = call("writefile", path, text)
	if not ok then
		return false, tostring(writeError)
	end
	return true
end

-- ==========================================================================
-- Index
-- ==========================================================================

local function blankIndex()
	return { order = {}, active = nil }
end

---The index, repaired in memory when the file is missing or malformed.
function Config:Index()
	local data = self:ReadJSON(self.INDEX)
	if type(data) ~= "table" then
		return blankIndex()
	end
	local index = blankIndex()
	if type(data.order) == "table" then
		for _, name in data.order do
			if type(name) == "string" then
				table.insert(index.order, name)
			end
		end
	end
	if type(data.active) == "string" then
		index.active = data.active
	end
	return index
end

local function positionOf(list, needle)
	for index, value in list do
		if value == needle then
			return index
		end
	end
	return nil
end

---Preset names in index order, plus the active one.
function Config:List()
	local index = self:Index()
	return table.clone(index.order), index.active
end

function Config:Active()
	return (self:Index()).active
end

-- ==========================================================================
-- Presets
-- ==========================================================================
-- Names become file names, so anything that could leave the folder, start
-- with a dot, or break a shell is refused up front instead of being silently
-- rewritten into something the user did not type.

local NAME_PATTERN = "^[%w][%w%-_ ]*$"
local NAME_LIMIT = 40

local function validName(name)
	if type(name) ~= "string" then
		return false, "the preset name must be text"
	end
	local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return false, "the preset name is empty"
	end
	if #trimmed > NAME_LIMIT then
		return false, ("the name is longer than %d characters"):format(NAME_LIMIT)
	end
	if not trimmed:match(NAME_PATTERN) then
		return false, "use letters, numbers, spaces, - and _ only"
	end
	-- Windows executors reject these outright; catching them here gives a
	-- better message than a writefile error.
	local reserved = { ["con"] = true, ["prn"] = true, ["aux"] = true, ["nul"] = true }
	if reserved[trimmed:lower()] then
		return false, ("'%s' is a reserved file name"):format(trimmed)
	end
	return true, trimmed
end
Config.validName = validName

function Config:Path(name)
	return ("%s/%s.json"):format(self.PRESET_DIR, name)
end

---Save `values` as `name`. Returns true, or false plus a reason.
function Config:SavePreset(name, values)
	local ok, cleanOrReason = validName(name)
	if not ok then
		return false, cleanOrReason
	end
	local clean = cleanOrReason

	if type(values) ~= "table" then
		return false, "there is nothing to save"
	end

	-- Only serialisable leaves: a flag whose value is a Color3 or a table with
	-- a metatable would make JSONEncode throw halfway through the file.
	local payload = {}
	local count = 0
	for flag, value in values do
		local kind = type(value)
		if kind == "string" or kind == "number" or kind == "boolean" then
			payload[flag] = value
			count += 1
		end
	end
	if count == 0 then
		return false, "no text, number or boolean values to save"
	end

	local written, writeError = self:WriteJSON(self:Path(clean), payload)
	if not written then
		return false, writeError
	end

	local index = self:Index()
	if not positionOf(index.order, clean) then
		table.insert(index.order, clean)
	end
	index.active = clean
	self:WriteJSON(self.INDEX, index)

	self:Changed("save", clean)
	return true, count
end

---Load a preset. Returns the values table, or nil plus a reason.
function Config:LoadPreset(name)
	local ok, cleanOrReason = validName(name)
	if not ok then
		return nil, cleanOrReason
	end
	local clean = cleanOrReason

	local data, readError = self:ReadJSON(self:Path(clean))
	if type(data) ~= "table" then
		return nil, readError or "the preset is not a table"
	end

	local index = self:Index()
	if index.active ~= clean then
		index.active = clean
		self:WriteJSON(self.INDEX, index)
	end

	self:Changed("load", clean)
	return data
end

---Delete a preset and drop it from the index. True even when the file cannot
---be removed: the index no longer lists it, which is what the user sees.
function Config:DeletePreset(name)
	local ok, cleanOrReason = validName(name)
	if not ok then
		return false, cleanOrReason
	end
	local clean = cleanOrReason

	local index = self:Index()
	local at = positionOf(index.order, clean)
	if at then
		table.remove(index.order, at)
	end
	if index.active == clean then
		index.active = index.order[1]
	end
	self:WriteJSON(self.INDEX, index)

	local remove = fn("delfile") or fn("deletefile")
	if remove then
		pcall(remove, self:Path(clean))
	end

	self:Changed("delete", clean)
	return true
end

---Rename keeps the index position and the file contents.
function Config:RenamePreset(name, newName)
	local ok, cleanOrReason = validName(name)
	if not ok then
		return false, cleanOrReason
	end
	local okNew, newCleanOrReason = validName(newName)
	if not okNew then
		return false, newCleanOrReason
	end
	local clean, newClean = cleanOrReason, newCleanOrReason

	if clean == newClean then
		return true
	end
	local values, readError = self:ReadJSON(self:Path(clean))
	if type(values) ~= "table" then
		return false, readError or "the preset could not be read"
	end

	local written, writeError = self:WriteJSON(self:Path(newClean), values)
	if not written then
		return false, writeError
	end

	local index = self:Index()
	local at = positionOf(index.order, clean)
	if at then
		index.order[at] = newClean
	else
		table.insert(index.order, newClean)
	end
	if index.active == clean then
		index.active = newClean
	end
	self:WriteJSON(self.INDEX, index)

	local remove = fn("delfile") or fn("deletefile")
	if remove then
		pcall(remove, self:Path(clean))
	end

	self:Changed("rename", newClean)
	return true
end

-- ==========================================================================
-- Change notification
-- ==========================================================================

-- Created in the factory, not here: the module body runs before FatCatInit
-- exists, so `Signal` is still nil at this point in the file.
Config.changed = nil

function Config:Changed(kind, name)
	self.changed:Fire(kind, name)
end

return function(core, signal)
	Core = core
	Signal = signal
	Config.changed = Signal.new("config:changed")
	return Config
end

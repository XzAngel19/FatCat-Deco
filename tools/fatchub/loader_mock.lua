-- Stand-in for the executor environment, used by tools/fatchub/loader_spec.lua.
-- tools/test_fatchub.sh prepends this to the loader and the assertions, so the
-- loader is tested in the shape it actually runs in, with no network.

-- print is replaced below, so keep the original under a name of its own. A
-- global (not a local) because the spec file lives in the same chunk.
REALPRINT = print

LOGS = {}
local function log(kind, ...)
	local t = { ... }
	for index = 1, #t do
		t[index] = tostring(t[index])
	end
	LOGS[#LOGS + 1] = kind .. " " .. table.concat(t, "\t")
end

-- BODY = whatever the next HttpGet returns. nil makes it throw, which is what
-- an executor does on a 404. URLS records every URL asked for, so a spec can
-- check that the loader walked the branches in order.
URLS = {}
FETCH_COUNT = 0
game = {
	HttpGet = function(_, url)
		LAST_URL = url
		URLS[#URLS + 1] = url
		FETCH_COUNT = FETCH_COUNT + 1
		return BODY or error("404: Not Found", 0)
	end,
}

typeof = function(value)
	return type(value)
end

getgenv = function()
	return _G
end

-- Local aliases, so a spec that redefines print/warn for a case cannot silence
-- its own output (a global print would be captured before the redefinition).
local log_ = log
local LOADER_START = debug and debug.info and nil or nil
print = function(...)
	log_("print", ...)
end

warn = function(...)
	log_("warn ", ...)
end

-- Only the library's own compile is simulated; the loader itself is inlined by
-- the runner, because a chunk that calls loadstring on the loader deadlocks
-- this VM.
loadstring = function(source, chunkName)
	if source:find("local broken", 1, true) then
		return nil, (chunkName or "chunk") .. ":37: unexpected symbol near ')'"
	end
	return function()
		_G.FatCatHub = {
			_window = { selected = "Main" },
			menuKey = "RightShift",
			Destroy = function() end,
		}
	end
end

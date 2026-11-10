-- Executor globals for Roblox injection.
--
-- A Roblox executor adds a namespace on top of the engine API. Unlike a menu
-- host, a decompiler or an injected script sees these names unqualified, so
-- they have to be declared or `luau-analyze` reports every one of them as
-- `Unknown global` and the real type errors drown.
--
-- Two rules, kept from the branch this file came from:
--   1. Only names that actually appear in the tree are declared. Add a line
--      when a new one shows up; never sprinkle `any` casts through sources.
--   2. Signatures are the documented executor ones, not guesses. Where
--      executors disagree (return arity, optional arguments) the widest common
--      shape is used and the note says why.

-- Environment and identity ------------------------------------------------
declare getgenv: () -> { [string]: any }
declare getrenv: () -> { [string]: any }
declare getreg: (any?) -> { [string]: any }
declare getgc: (boolean?) -> { any }
declare getinstances: () -> { Instance }
declare getnilinstances: () -> { Instance }
declare getscripts: () -> { LuaSourceContainer }
declare getloadedmodules: () -> { ModuleScript }
declare getrunningscripts: () -> { LuaSourceContainer }
declare getscriptfromthread: (thread) -> LuaSourceContainer?
declare getcallingscript: () -> LuaSourceContainer?
declare getthreadidentity: () -> number
declare setthreadidentity: (number) -> ()

-- Metatables and raw access ------------------------------------------------
-- Executors also spell these `getrawmetatable` and `setrawmetatable`; both are
-- declared because both spellings are in the wild and in this tree.
declare getrawmetatable: (any) -> { [string]: any }
declare setrawmetatable: (any, { [string]: any }) -> ()
declare setreadonly: (any, boolean) -> ()
declare isreadonly: (any) -> boolean
declare make_writeable: (any) -> ()
declare hookmetamethod: (any, string, (...any) -> ...any) -> (...any) -> ...any
declare getnamecallmethod: () -> string?
declare setnamecallmethod: (string) -> ()

-- Function work ------------------------------------------------------------
declare hookfunction: (any, any) -> any
declare restorefunction: (any) -> ()
declare replaceclosure: (any, any) -> ()
declare isfunctionhooked: (any) -> boolean
declare ishooked: (any) -> boolean
declare clonefunction: (any) -> any
declare newcclosure: ((...any) -> ...any) -> (...any) -> ...any
declare checkcaller: () -> boolean
declare islclosure: (any) -> boolean
declare iscclosure: (any) -> boolean
declare isexecutorclosure: (any) -> boolean
declare getfunctionhash: (any) -> string
declare getcallbackvalue: (any, string) -> any
declare getfunctioninfo: (any) -> (any, string, number)
declare dumpstring: (string) -> string
declare firetouchinterest: (any, any, number) -> ()
declare fireclickdetector: (any, number?, boolean?) -> ()
declare fireproximityprompt: (any, number?, boolean?) -> ()
declare firelclickdetector: (any, number?, boolean?) -> ()
declare gethiddenproperty: (any, string) -> (any, boolean)
declare sethiddenproperty: (any, string, any) -> (boolean, string?)

-- Instances and GUI --------------------------------------------------------
declare gethui: () -> Instance
declare protectgui: (Instance) -> ()
declare synprotect: (string) -> any
declare getcustomasset: (string) -> string
declare cloneref: (any) -> any
declare clonereference: (any) -> any
-- `script` is the enclosing LuaSourceContainer. Only declared where the chunk
-- is a members of a script tree; a bare injected chunk reads it as nil.
declare script: LuaSourceContainer
declare compareinstances: (Instance, Instance) -> boolean
declare identifyexecutor: () -> (string, string)
declare getexecutorname: () -> (string, string)
declare getscripthash: (any) -> string
declare setfpscap: (number) -> ()
declare getfpscap: () -> number

-- Filesystem ---------------------------------------------------------------
declare readfile: (string) -> string
declare writefile: (string, string) -> ()
declare appendfile: (string, string) -> ()
declare isfile: (string) -> boolean
declare isfolder: (string) -> boolean
declare makefolder: (string) -> ()
declare delfile: (string) -> ()
declare delfolder: (string) -> ()
declare listfiles: (string) -> { string }
declare setclipboard: (string) -> ()

-- Script dumps and decompilation ------------------------------------------
-- A decompiler's own inputs: `decompile` returns source text and
-- `getscriptbytecode` the pre-unpacked `.luauc` container. Both are declared
-- here because the analysis pass has to see the reader side too.
declare decompile: (any) -> string
declare getscriptbytecode: (any) -> string
declare getscriptclosure: (any) -> any
declare getscriptfunction: (any) -> any
declare getscriptenv: (any) -> { [string]: any }
declare setscriptable: (any, boolean) -> ()
declare get_signal_cons: (any) -> { any }
declare getconnections: (any) -> { any }
declare firesignal: (any, ...any) -> ()
declare getcallingscriptname: () -> string?

-- Network ------------------------------------------------------------------
declare request: (any) -> any
declare synrequest: (any) -> any
declare http_request: (any) -> any
declare queue_on_teleport: (string) -> ()
declare queueonteleport: (string) -> ()
declare setfflag: (string, string) -> ()
declare getfflag: (string) -> any
declare run_on_actor: (any, string, ...any) -> ...any
declare getactors: () -> { any }
declare getdeletedactors: () -> { any }
declare on_actor_state_created: (any) -> any
declare create_comm_channel: () -> any

-- GC filtering -------------------------------------------------------------
declare filtergc: (any, any, boolean?) -> any
declare setstackhidden: (boolean) -> ()

-- Globals and misc ---------------------------------------------------------
declare GLOBAL: any
-- `__F` and `oth` are Volcano/oth executor table exposures, reached
-- unqualified inside code written for that executor.
declare __F: any
declare oth: { [string]: any }
declare SharedTable: any
declare tick: () -> number
declare time: () -> number
declare warn: (...any) -> ()
declare typeof: (any) -> string

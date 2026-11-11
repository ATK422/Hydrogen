--!strict

-- Strict type checks of game code that uses Hydrogen, with the luau-lsp version create_hydrogen
-- pins (1.70.1). CI runs `luau-lsp analyze` on this folder with Hydrogen's own source ignored,
-- which is what a game's CI sees: only errors at the call sites. Nothing here runs; every line
-- must type-check with no errors. Add a case when a public type changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require("../../src")
local gt = Hydrogen.gt

-- The generated Main scripts: app:start() must accept the App type (T5).
local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage)
app:addSystemsFolders(ReplicatedStorage)
app:start()
app:stop()

-- Fields that were declared `read`, which this luau-lsp can't see (T5).
local scope = Hydrogen.Scope.new()
local _alive: boolean = scope.alive
local _scopeName: string? = scope.name
local timer = Hydrogen.Scheduler.after(1, function() end)
local _active: boolean = timer.active
local _paused: boolean = timer.paused
local signal = Hydrogen.Signal.new() :: Hydrogen.Signal<number>
local connection = signal:Connect(function(_n: number) end)
local _connected: boolean = connection.Connected

-- Literal unions in schemas: annotate the network object, cast the constructor (T5). The schema
-- still validates at runtime; the annotation is what keeps "M1" | "M2" instead of string.
type Move = "M1" | "M2"
local MoveSchema = gt.union(gt.literal("M1"), gt.literal("M2"))
local Attack: Hydrogen.ClientEvent<Move> = Hydrogen.clientEvent("TypesAttack", MoveSchema) :: any
Attack:On(function(_player: Player, move)
	local _move: Move = move
end)
Attack:Fire("M1")
local Played: Hydrogen.ServerEvent<Move, number> = Hydrogen.serverEvent("TypesPlayed", MoveSchema, gt.number()) :: any
Played:FireAll("M2", 4)
local Ask: Hydrogen.ClientFunction<(Move), (boolean)> =
	Hydrogen.clientFunction("TypesAsk", gt.args(MoveSchema), gt.returns(gt.boolean())) :: any
local _accepted: boolean = Ask:Fire("M1")

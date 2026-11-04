--!strict

-- Turns what each side registered while booting into diagnostics.

local Probe = require("./Probe")
local World = require("./World")

type Side = World.Side
type Frame = World.Frame
type Snapshot = Probe.Snapshot
type Registration = Probe.Registration

export type Severity = "error" | "warning"

export type Location = {
	side: Side,
	file: string,
	line: number,
	instance: string?,
}

export type Diagnostic = {
	rule: string,
	severity: Severity,
	-- The network name it is about, when there is one.
	name: string?,
	sides: { Side },
	message: string,
	fix: string?,
	locations: { Location },
}

export type Booted = {
	side: Side,
	world: World.World,
	probe: Probe.Probe,
	snapshot: Snapshot,
}

-- Every rule, in the order the report lists them.
local RULES: { { name: string, severity: Severity, summary: string } } = {
	{ name = "script-error", severity = "error", summary = "a script errored while the game booted" },
	{ name = "multiple-runtimes", severity = "error", summary = "two copies of Hydrogen loaded on one side" },
	{ name = "addnetwork-hang", severity = "error", summary = "app:addNetwork would loop forever on a module's value" },
	{ name = "one-sided", severity = "error", summary = "a network name is registered on one side only" },
	{ name = "duplicate", severity = "error", summary = "a network name is registered twice" },
	{ name = "late-registration", severity = "error", summary = "a network object is created after the network started" },
	{ name = "kind-mismatch", severity = "error", summary = "the sides disagree on what kind of object a name is" },
	{ name = "encode-mismatch", severity = "error", summary = ":Encode() is called on one side only" },
	{ name = "schema-mismatch", severity = "error", summary = "the sides have different schemas for a name" },
	{ name = "missing-returns", severity = "error", summary = "a serverFunction is never given its returns" },
	{ name = "function-schema", severity = "error", summary = "a clientFunction isn't given gt.args(...) and gt.returns(...)" },
	{ name = "stalled", severity = "warning", summary = "a script never finished and the network never started" },
	{ name = "not-started", severity = "warning", summary = "names were registered but no app started the network" },
	{ name = "no-scripts", severity = "warning", summary = "the lint found no scripts to run on a side" },
	{ name = "no-handler", severity = "warning", summary = "nothing on the receiving side listens or answers" },
	{ name = "similar-names", severity = "warning", summary = "two names differ only by case" },
	{ name = "reserved-prefix", severity = "warning", summary = "a name uses a prefix Hydrogen uses for its own objects" },
	{ name = "runtime-warning", severity = "warning", summary = "Hydrogen warned while the game booted" },
}

local Rules = {}

Rules.list = RULES

local ruleOrder: { [string]: number } = {}
for index, rule in RULES do
	ruleOrder[rule.name] = index
end

local function title(side: Side): string
	return if side == "server" then "Server" else "Client"
end

local function at(side: Side, frame: Frame?): { Location }
	if not frame then
		return {}
	end
	return { { side = side, file = frame.file, line = frame.line, instance = frame.instance } }
end

local function firstLine(text: string): string
	return string.match(text, "^[^\n]*") or text
end

local function where(frame: Frame?): string
	if not frame then
		return "an unknown module"
	end
	return frame.instance or frame.file
end

-- Diagnostics the two sides would report the same way become one, listing both sides.
local function merge(diagnostics: { Diagnostic }): { Diagnostic }
	local merged: { Diagnostic } = {}
	local byKey: { [string]: Diagnostic } = {}
	for _, diagnostic in diagnostics do
		local key = `{diagnostic.rule}\0{diagnostic.name or ""}\0{diagnostic.message}`
		for _, location in diagnostic.locations do
			key ..= `\0{location.file}:{location.line}`
		end
		local existing = byKey[key]
		if existing then
			for _, side in diagnostic.sides do
				if not table.find(existing.sides, side) then
					table.insert(existing.sides, side)
				end
			end
		else
			byKey[key] = diagnostic
			table.insert(merged, diagnostic)
		end
	end
	return merged
end

local function scriptChecks(side: Booted, into: { Diagnostic })
	local started = side.snapshot.started
	for _, run in side.world.scripts do
		if run.status == "errored" then
			local frame = nil
			for _, candidate in run.frames do
				if not side.probe:isHydrogen(candidate) then
					frame = candidate
					break
				end
			end
			frame = frame or run.frames[1]

			local message = `{title(side.side)} script {run.instance} errored{if run.afterStart then " after the network started" else ""}: {firstLine(run.error or "")}`
			local fix = if run.afterStart
				then "The network checks still ran. The lint has no real other side, so a call that waits for an answer (a function fired from a start hook) can fail here; if it works in Studio, ignore this."
				else `Network objects this script would have registered after the error weren't checked on the {side.side}. Fix the error; if it's an engine API the lint doesn't emulate, move that call into a system's start hook.`
			table.insert(into, {
				rule = "script-error",
				severity = if run.afterStart then "warning" else "error",
				name = nil,
				sides = { side.side },
				message = message,
				fix = fix,
				locations = at(side.side, frame),
			})
		elseif run.status == "running" and not started then
			table.insert(into, {
				rule = "stalled",
				severity = "warning",
				name = nil,
				sides = { side.side },
				message = `{title(side.side)} script {run.instance} never finished, and the network never started on the {side.side}`,
				fix = "It is waiting on something the lint doesn't emulate (shown at the location). The names registered so far were still compared.",
				locations = at(side.side, run.frames[1]),
			})
		end
	end

	if #side.world.scripts == 0 then
		table.insert(into, {
			rule = "no-scripts",
			severity = "warning",
			name = nil,
			sides = { side.side },
			message = if side.side == "server"
				then "No server scripts found in ServerScriptService or Workspace"
				else "No client scripts found in ReplicatedFirst, StarterPlayer, StarterGui or StarterPack",
			fix = "Check the Rojo project maps your scripts (`.server.luau` / `.client.luau` files) into those services.",
			locations = {},
		})
	elseif #side.snapshot.names > 0 and not started then
		local erroredOrStalled = false
		for _, run in side.world.scripts do
			if run.status ~= "finished" then
				erroredOrStalled = true
			end
		end
		if not erroredOrStalled then
			table.insert(into, {
				rule = "not-started",
				severity = "warning",
				name = nil,
				sides = { side.side },
				message = `{#side.snapshot.names} network names were registered on the {side.side}, but no app:start() ran there`,
				fix = `Create an App in the {side.side}'s entry script, addNetwork the shared folder, and call app:start().`,
				locations = {},
			})
		end
	end

	if #side.snapshot.runtimes > 1 then
		table.insert(into, {
			rule = "multiple-runtimes",
			severity = "error",
			name = nil,
			sides = { side.side },
			message = `The {side.side} loaded {#side.snapshot.runtimes} copies of Hydrogen: {table.concat(side.snapshot.runtimes, ", ")}`,
			fix = "Each copy has its own network registry and fights over the same remotes. Require Hydrogen from one place (ReplicatedStorage.roblox_packages.hydrogen), and make packages that depend on it share that version.",
			locations = {},
		})
	end

	for _, warning in side.world.warnings do
		local text = warning.text
		if not string.find(text, "[HYDROGEN]", 1, true) or string.find(text, "NETWORK MISMATCH", 1, true) then
			continue
		end
		local frame = nil
		for _, candidate in warning.frames do
			if not side.probe:isHydrogen(candidate) then
				frame = candidate
				break
			end
		end
		table.insert(into, {
			rule = "runtime-warning",
			severity = "warning",
			name = nil,
			sides = { side.side },
			message = firstLine(text),
			fix = nil,
			locations = at(side.side, frame),
		})
	end
end

local function registrationChecks(side: Booted, into: { Diagnostic })
	local snapshot = side.snapshot

	for _, pair in snapshot.duplicates do
		local first, second = pair.first, pair.second
		local fix = "Names must be unique. Rename one, or give each place its own prefix with Hydrogen.namespace(\"...\")."
		if first.via or second.via then
			fix = `{first.via or second.via} names its network objects itself (Hydrogen.State uses State/<name>), so a state and another object can't share that name. Rename one.`
		end
		local locations = at(side.side, first.site)
		for _, location in at(side.side, second.site) do
			table.insert(locations, location)
		end
		table.insert(into, {
			rule = "duplicate",
			severity = "error",
			name = first.name,
			sides = { side.side },
			message = if where(first.site) == where(second.site)
				then `"{first.name}" is registered twice in {where(first.site)}`
				else `"{first.name}" is registered twice: in {where(first.site)} and in {where(second.site)}`,
			fix = fix,
			locations = locations,
		})
	end

	for _, hang in snapshot.hangs do
		table.insert(into, {
			rule = "addnetwork-hang",
			severity = "error",
			name = nil,
			sides = { side.side },
			message = `app:addNetwork never returns on {hang.module}: its value has a callable table at {if hang.path == "" then "the top" else hang.path} (a State object or a GreenTea schema), and Hydrogen's object count calls it forever`,
			fix = "This Hydrogen version counts objects with a generic for, which calls tables that have __call. Until it is fixed, keep State objects and bare schemas in a module your systems require (both sides, at require time), not one passed to addNetwork.",
			locations = if hang.file then { { side = side.side, file = hang.file, line = 1, instance = hang.module } } else {},
		})
	end

	for _, record in snapshot.late do
		-- The definition is usually fine; what matters is the code that first required it late.
		local from = nil
		local site = record.site
		for _, frame in record.frames do
			if site and frame.file ~= site.file and not side.probe:isHydrogen(frame) then
				from = frame
				break
			end
		end
		local locations = at(side.side, site)
		for _, location in at(side.side, from) do
			table.insert(locations, location)
		end
		local cause = if from then `, required from {where(from)}` else ""
		table.insert(into, {
			rule = "late-registration",
			severity = "error",
			name = record.name,
			sides = { side.side },
			message = `"{record.name}" is created after the network started on the {side.side}, so Hydrogen ignores it (made in {where(site)}{cause})`,
			fix = "Define network objects in a shared module that both sides require before app:start(), usually by passing its folder to app:addNetwork. An object made later has no id, and using it errors with \"Network event ... not found\".",
			locations = locations,
		})
	end

	for _, record in snapshot.builders do
		table.insert(into, {
			rule = "missing-returns",
			severity = "error",
			name = record.name,
			sides = { side.side },
			message = `serverFunction "{record.name}" is never given its returns, so it is never registered`,
			fix = `serverFunction is curried: Hydrogen.serverFunction("{record.name}", args...)(returns...). Call the result, with no arguments if it returns nothing.`,
			locations = at(side.side, record.site),
		})
	end

	for _, issue in snapshot.functionIssues do
		local message, fix, severity: Severity
		if issue.problem == "missing-returns" then
			message = `clientFunction "{issue.name}" has no returns schema`
			fix = `Hydrogen.clientFunction("{issue.name}", gt.args(...), gt.returns(...)). Use gt.returns() when it returns nothing; without it every answer fails validation.`
			severity = "error"
		elseif issue.problem == "extra-arguments" then
			message = `clientFunction "{issue.name}" is given more than two schemas; the extra ones are ignored`
			fix = "Wrap the argument schemas in gt.args(...) and the return schemas in gt.returns(...)."
			severity = "error"
		else
			message = `clientFunction "{issue.name}" takes its schemas as gt.args(...) and gt.returns(...)`
			fix = "A bare schema works for a single value but doesn't type-check, and can't describe several. Wrap them: gt.args(gt.string()), gt.returns(gt.number())."
			severity = "warning"
		end
		table.insert(into, {
			rule = "function-schema",
			severity = severity,
			name = issue.name,
			sides = { side.side },
			message = message,
			fix = fix,
			locations = at(side.side, issue.site),
		})
	end

	for _, name in snapshot.names do
		local entry = snapshot.entries[name]
		if entry.registration.via == nil then
			for _, prefix in { "State/", "Hydrogen/" } do
				if string.sub(name, 1, #prefix) == prefix then
					table.insert(into, {
						rule = "reserved-prefix",
						severity = "warning",
						name = name,
						sides = { side.side },
						message = `"{name}" starts with "{prefix}", which Hydrogen uses for its own network objects`,
						fix = "Pick another name or prefix, so a future state or kit module can't collide with it.",
						locations = at(side.side, entry.registration.site),
					})
				end
			end
		end
	end
end

local function containersText(snapshot: Snapshot): string
	local all = {}
	for _, call in snapshot.addNetwork do
		for _, container in call.containers do
			table.insert(all, container)
		end
	end
	return if #all == 0 then "nothing" else table.concat(all, ", ")
end

local function erroredEarly(side: Booted): boolean
	for _, run in side.world.scripts do
		if (run.status == "errored" and not run.afterStart) or (run.status == "running" and not side.snapshot.started) then
			return true
		end
	end
	return false
end

local function oneSided(from: Booted, to: Booted, name: string): Diagnostic
	local entry = from.snapshot.entries[name]
	local registration = entry.registration
	local site = registration.site
	local instance = site and site.instance
	local fix

	if World.serverOnly(instance) then
		fix = `It's defined in {instance}, which clients can't see. Move it to a shared module (such as ReplicatedStorage.Shared.Network) and pass that folder to app:addNetwork on both sides.`
	elseif World.clientOnly(instance) then
		fix = `It's defined in {instance}, which only clients run. Move it to a shared module (such as ReplicatedStorage.Shared.Network) and pass that folder to app:addNetwork on both sides.`
	elseif registration.via then
		fix = `{registration.via} registered it for a definition in {where(site)}. Require that module on the {to.side} too, before app:start().`
	else
		fix = `The {to.side} never required {where(site)}. Pass its folder to app:addNetwork in the {to.side}'s entry script too, before app:start(). addNetwork on the server: {containersText(from.side == "server" and from.snapshot or to.snapshot)}; on the client: {containersText(from.side == "client" and from.snapshot or to.snapshot)}.`
	end
	if erroredEarly(to) then
		fix ..= ` The {to.side} stopped booting early (see the script-error or stalled diagnostic), which may be why.`
	end

	return {
		rule = "one-sided",
		severity = "error",
		name = name,
		sides = { from.side },
		message = `{entry.kind} "{name}" is registered on the {from.side} only`,
		fix = `Ids come from the sorted names, so every name after it reaches the wrong object. {fix}`,
		locations = at(from.side, site),
	}
end

local function bothSides(server: Booted, client: Booted, name: string, into: { Diagnostic })
	local a, b = server.snapshot.entries[name], client.snapshot.entries[name]
	local locations = at("server", a.registration.site)
	for _, location in at("client", b.registration.site) do
		table.insert(locations, location)
	end

	if a.kind ~= b.kind then
		table.insert(into, {
			rule = "kind-mismatch",
			severity = "error",
			name = name,
			sides = { "server", "client" },
			message = `"{name}" is a {a.kind} on the server but a {b.kind} on the client`,
			fix = "Define each network object once, in a shared module both sides require, instead of once per side.",
			locations = locations,
		})
		return
	end

	if a.encode ~= b.encode then
		local only: Side = if a.encode then "server" else "client"
		table.insert(into, {
			rule = "encode-mismatch",
			severity = "error",
			name = name,
			sides = { "server", "client" },
			message = `"{name}" calls :Encode() on the {only} only`,
			fix = `Call :Encode() in the shared definition, not behind a RunService check. One side sends buffers the other reads as invalid arguments, and drops.`,
			locations = locations,
		})
	end

	local differences = {}
	if a.schema ~= b.schema then
		table.insert(differences, `server {a.schema}, client {b.schema}`)
	end
	if a.args ~= b.args then
		table.insert(differences, `args: server {a.args}, client {b.args}`)
	end
	if a.returns ~= b.returns then
		table.insert(differences, `returns: server {a.returns}, client {b.returns}`)
	end
	if #differences > 0 then
		table.insert(into, {
			rule = "schema-mismatch",
			severity = "error",
			name = name,
			sides = { "server", "client" },
			message = `"{name}" has different schemas on each side ({table.concat(differences, "; ")})`,
			fix = "Each side validates with its own schema, so messages that match one side's are dropped by the other. Define the object once in a shared module.",
			locations = locations,
		})
	end

	-- Kit modules wire their own objects up, sometimes lazily.
	if a.registration.via or b.registration.via then
		return
	end
	local receiver = if a.kind == "ServerEvent" or a.kind == "ServerFunction" then client else server
	local entry = receiver.snapshot.entries[name]
	if receiver.snapshot.started and not entry.handled then
		local event = a.kind == "ServerEvent" or a.kind == "ClientEvent"
		table.insert(into, {
			rule = "no-handler",
			severity = "warning",
			name = name,
			sides = { receiver.side },
			message = if event
				then `Nothing on the {receiver.side} listens to {a.kind} "{name}" after the game booted`
				else `Nothing on the {receiver.side} answers {a.kind} "{name}" after the game booted`,
			fix = if event
				then `Connect a listener with :On(...) in a {receiver.side} system's init or start. Messages that arrive with no listener are dropped with a warning.`
				else `Set the handler with :On(...) in a {receiver.side} system's init or start. Until then, calls get no answer.`,
			locations = at(receiver.side, entry.registration.site),
		})
	end
end

local function nameChecks(server: Booted, client: Booted, into: { Diagnostic })
	local all: { [string]: boolean } = {}
	for _, side in { server, client } do
		for _, name in side.snapshot.names do
			all[name] = true
		end
	end

	local sorted = {}
	for name in all do
		table.insert(sorted, name)
	end
	table.sort(sorted)

	local byLower: { [string]: { string } } = {}
	for _, name in sorted do
		local onServer = server.snapshot.entries[name] ~= nil
		local onClient = client.snapshot.entries[name] ~= nil
		if onServer and onClient then
			bothSides(server, client, name, into)
		elseif onServer then
			table.insert(into, oneSided(server, client, name))
		else
			table.insert(into, oneSided(client, server, name))
		end

		local lower = string.lower(name)
		byLower[lower] = byLower[lower] or {}
		table.insert(byLower[lower], name)
	end

	for _, group in byLower do
		if #group > 1 then
			local entry = server.snapshot.entries[group[1]] or client.snapshot.entries[group[1]]
			local side: Side = if server.snapshot.entries[group[1]] then "server" else "client"
			table.insert(into, {
				rule = "similar-names",
				severity = "warning",
				name = group[1],
				sides = { side },
				message = `Network names {table.concat(group, " and ")} differ only by case`,
				fix = "These are separate objects. If they are meant to be one, use the same spelling everywhere.",
				locations = at(side, entry.registration.site),
			})
		end
	end
end

-- Diagnostics for a booted server and client, most severe and most fundamental first.
function Rules.check(server: Booted, client: Booted): { Diagnostic }
	local diagnostics: { Diagnostic } = {}
	for _, side in { server, client } do
		scriptChecks(side, diagnostics)
		registrationChecks(side, diagnostics)
	end
	nameChecks(server, client, diagnostics)

	diagnostics = merge(diagnostics)
	for _, diagnostic in diagnostics do
		table.sort(diagnostic.sides, function(left, right)
			return left == "server" and right == "client"
		end)
	end

	table.sort(diagnostics, function(left, right)
		if left.severity ~= right.severity then
			return left.severity == "error"
		end
		local leftOrder, rightOrder = ruleOrder[left.rule] or 0, ruleOrder[right.rule] or 0
		if leftOrder ~= rightOrder then
			return leftOrder < rightOrder
		end
		if (left.name or "") ~= (right.name or "") then
			return (left.name or "") < (right.name or "")
		end
		return left.message < right.message
	end)
	return diagnostics
end

return Rules

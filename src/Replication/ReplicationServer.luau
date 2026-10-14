local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DefineHooks = require(script.Parent.Parent.Util.DefineHooks)
local ReplicationShared = require(script.Parent.ReplicationShared)
local ChannelRegistry = require(script.Parent.ReplicationShared.ChannelRegistry)
local RemoteSerialization = require(script.Parent.Parent.Remotes.RemoteSerialization)

type SnapshotPreparerAsync = (player: Player) -> (boolean, any)

local readyPlayers: { [Player]: true } = {}
local fetchingPlayers: { [Player]: true } = {}

local channelIds: { [string]: number } = {}
local lastChannelId = 0
local knownChannelIds: { [Player]: { [number]: true } } = {}

-- studio only: replicators whose values have already been reported as not surviving a remote
local reportedSerializationIssues: { [string]: true } = {}
local snapshotPreparersAsync: { [string]: SnapshotPreparerAsync } = {}

local ReplicationServer = {}

-- public
function ReplicationServer.openChannel(channel: ChannelRegistry.Channel, key: string)
	channel:setKey(key)
	ChannelRegistry.addChannel(channel)
	lastChannelId += 1
	channelIds[key] = lastChannelId
	ReplicationServer._checkTypeSerialization(channel)

	-- players that already fetched never saw this key in their snapshot, so publish it to them now
	for player in readyPlayers do
		task.spawn(ReplicationServer._publishCurrentAsync, channel, player)
	end
end

-- prepare runs before a snapshot is read for a player; returning false means the player is not ready yet
function ReplicationServer.setSnapshotPreparer(kind: string, prepareAsync: SnapshotPreparerAsync)
	snapshotPreparersAsync[kind] = prepareAsync
end

function ReplicationServer.getReadyPlayers(): { Player }
	local players = {}
	for player in readyPlayers do
		table.insert(players, player)
	end
	return players
end

function ReplicationServer.publish(channel: ChannelRegistry.Channel, player: Player, payload: ReplicationShared.Payload)
	if not readyPlayers[player] then
		return
	end
	ReplicationServer._send(channel, player, payload)
end

function ReplicationServer.publishToReadyPlayers(channel: ChannelRegistry.Channel, payload: ReplicationShared.Payload)
	for player in readyPlayers do
		ReplicationServer._send(channel, player, payload)
	end
end

function ReplicationServer.getValidatedPayload(
	channel: ChannelRegistry.Channel,
	payloadContent: any,
	kind: ReplicationShared.PayloadKinds
): ReplicationShared.Payload?
	local valid = if kind == "value"
		then ReplicationServer.validateValue(channel, payloadContent)
		else ReplicationServer.validatePatch(channel, payloadContent)

	if not valid then
		return
	end

	return ReplicationServer.createPayload(channel, payloadContent, kind)
end

function ReplicationServer.createPayload(
	channel: ChannelRegistry.Channel,
	payloadContent: any,
	kind: ReplicationShared.PayloadKinds
): ReplicationShared.Payload
	ReplicationServer._validateSerialization(channel, payloadContent, kind)
	return if kind == "value"
		then { kind = "value", value = payloadContent }
		else { kind = "patch", patch = payloadContent }
end

function ReplicationServer.validateValue(channel: ChannelRegistry.Channel, value: any): boolean
	return ReplicationServer._validateTypes(channel, channel.typechecker, value, "value")
end

function ReplicationServer.validatePatch(channel: ChannelRegistry.Channel, patch: any): boolean
	return ReplicationServer._validateTypes(
		channel,
		assert(channel.patchTypechecker, `Replicator {channel.key} has no patch type`),
		patch,
		"patch"
	)
end

-- private
function ReplicationServer._send(channel: ChannelRegistry.Channel, player: Player, payload: ReplicationShared.Payload)
	local id = channelIds[channel.key]
	local known = knownChannelIds[player]
	if known[id] then
		ReplicationShared.streamRemote:fireClient(player, id, payload)
	else
		known[id] = true
		ReplicationShared.streamRemote:fireClient(player, id, payload, channel.key)
	end
end

function ReplicationServer._validateTypes(
	channel: ChannelRegistry.Channel,
	checker: any,
	data: any,
	label: string
): boolean
	local ok, cause = checker:matches(data)
	if not ok then
		warn(`Replicator {channel.key} produced a {label} that does not match its type:\n{cause:formatErr()}`)
		return false
	end
	return true
end

function ReplicationServer._validateSerialization(channel: ChannelRegistry.Channel, data: any, label: string)
	local reportKey = `{channel.key}:{label}`
	if not RunService:IsStudio() or reportedSerializationIssues[reportKey] then
		return
	end

	local issue = RemoteSerialization.findIssue(data)
	if issue then
		reportedSerializationIssues[reportKey] = true
		warn(`Replicator {channel.key}'s {label} may not arrive intact on the client: {issue}`)
	end
end

function ReplicationServer._checkTypeSerialization(channel: ChannelRegistry.Channel)
	local valueIssue = RemoteSerialization.findTypeIssue(channel.typechecker, "value")
	if valueIssue then
		warn(`Replicator {channel.key}'s type won't arrive intact on the client: {valueIssue}`)
	end

	if channel.patchTypechecker then
		local patchIssue = RemoteSerialization.findTypeIssue(channel.patchTypechecker, "patch")
		if patchIssue then
			warn(`Replicator {channel.key}'s patch type won't arrive intact on the client: {patchIssue}`)
		end
	end
end

function ReplicationServer._prepareAsync(kinds: { [string]: true }, player: Player): (boolean, { [string]: any })
	local contexts = {}
	for kind in kinds do
		local prepareAsync = snapshotPreparersAsync[kind]
		if prepareAsync then
			local ok, context = prepareAsync(player)
			if not ok then
				return false, contexts
			end
			contexts[kind] = context
		end
	end
	return true, contexts
end

function ReplicationServer._publishCurrentAsync(channel: ChannelRegistry.Channel, player: Player)
	local ok, contexts = ReplicationServer._prepareAsync({ [channel.kind] = true }, player)
	if not ok then
		return
	end

	local validatedPayload =
		ReplicationServer.getValidatedPayload(channel, channel.read(player, contexts[channel.kind]), "value")
	if not validatedPayload then
		return
	end

	ReplicationServer.publish(channel, player, validatedPayload)
end

function ReplicationServer._tryFetchAsync(player: Player): (boolean, ReplicationShared.Snapshot?)
	if readyPlayers[player] or fetchingPlayers[player] then
		return false, nil
	end

	-- only prepare kinds that have channels, so an unused kind can never block the fetch
	local kinds: { [string]: true } = {}
	for _, channel in ChannelRegistry.getChannels() do
		kinds[channel.kind] = true
	end

	fetchingPlayers[player] = true
	local didRun, prepared, contexts = pcall(ReplicationServer._prepareAsync, kinds, player)
	fetchingPlayers[player] = nil

	if not didRun then
		warn(`Replication snapshot for {player.Name} failed to prepare: {prepared}`)
		return false, nil
	end

	if not prepared or player.Parent == nil then
		return false, nil
	end

	-- no yielding from here until the player is marked ready
	local snapshot: ReplicationShared.Snapshot = {}
	local known: { [number]: true } = {}
	for key, channel in pairs(ChannelRegistry.getChannels()) do
		local value = channel.read(player, contexts[channel.kind])
		local payload = ReplicationServer.getValidatedPayload(channel, value, "value")
		if payload then
			local id = channelIds[key]
			snapshot[key] = { id = id, payload = payload :: ReplicationShared.ValuePayload }
			known[id] = true
		end
	end
	knownChannelIds[player] = known
	readyPlayers[player] = true

	return true, snapshot
end

-- start
if RunService:IsServer() and RunService:IsRunning() then
	DefineHooks.run(
		ReplicationShared.fetchRemote,
		ReplicationShared.FETCH_REMOTE_NAME,
		ReplicationShared.SENCHA_MODULE
	)
	DefineHooks.run(
		ReplicationShared.streamRemote,
		ReplicationShared.STREAM_REMOTE_NAME,
		ReplicationShared.SENCHA_MODULE
	)

	ReplicationShared.fetchRemote:onServerInvoke(ReplicationServer._tryFetchAsync)

	Players.PlayerRemoving:Connect(function(player)
		readyPlayers[player] = nil
		fetchingPlayers[player] = nil
		knownChannelIds[player] = nil
	end)
end

return ReplicationServer

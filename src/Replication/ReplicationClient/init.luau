local RunService = game:GetService("RunService")

local DefineHooks = require(script.Parent.Parent.DefineHooks)
local ReplicationShared = require(script.Parent.ReplicationShared)
local ObservableValue = require(script.Parent.Parent.Parent.ObservableValue)
local ChannelRegistry = require(script.Parent.ReplicationShared.ChannelRegistry)

local FETCH_RETRY_SECONDS = 0.5
local SLOW_LOAD_WARNING_SECONDS = 5

local RESYNC_BASE_DELAY_SECONDS = 2
local RESYNC_MAX_DELAY_SECONDS = 30
local RESYNC_WARN_AFTER_ATTEMPTS = 5

local fetchStarted = false
local initialFetchComplete = ObservableValue.new(false)
-- for keys whose module the client hasn't required yet: the latest value, then patches received after it
local latestPayloads: { [string]: ReplicationShared.ValuePayload } = {}
local pendingPatches: { [string]: { any } } = {}
local resyncingKeys: { [string]: number } = {}
local channelKeys: { [number]: string } = {}

type StreamMessage = { id: number, payload: ReplicationShared.Payload, key: string? }

local ReplicationClient = {}
ReplicationClient.SLOW_LOAD_WARNING_SECONDS = SLOW_LOAD_WARNING_SECONDS

-- public
function ReplicationClient.openChannel(channel: ChannelRegistry.Channel, key: string)
	channel:setKey(key)
	ChannelRegistry.addChannel(channel)
	ReplicationClient._initializeChannelValue(channel)

	latestPayloads[channel.key] = nil
	pendingPatches[channel.key] = nil
	ReplicationClient._startFetch()
end

function ReplicationClient.isInitialFetchComplete(): boolean
	return initialFetchComplete:get()
end

function ReplicationClient.waitForInitialFetch()
	if initialFetchComplete:get() then
		return
	end
	ReplicationClient._startFetch()

	local warnThread = task.delay(SLOW_LOAD_WARNING_SECONDS, function()
		local pendingKeys = {}
		for key in ChannelRegistry.getChannels() do
			table.insert(pendingKeys, key)
		end
		table.sort(pendingKeys)
		warn(
			`Sencha.waitForReplicators has waited {SLOW_LOAD_WARNING_SECONDS}s for replicator values from the server.`
				.. ` If saved replicators are used, make sure each saved source has its fetch function set on the server and its data is loading.`
				.. ` Waiting on: {if #pendingKeys > 0 then table.concat(pendingKeys, ", ") else "(none registered yet)"}`
		)
	end)

	initialFetchComplete
		:promiseValue(function(complete)
			return complete, nil
		end)
		:expect()
	task.cancel(warnThread)
end

-- private
function ReplicationClient._initializeChannelValue(channel: ChannelRegistry.Channel)
	local payload = latestPayloads[channel.key]
	if not payload then
		return
	end

	-- the module defining this replicator may be required after its value already arrived
	local didReceive = channel:receive(payload.value)
	if not didReceive then
		ReplicationClient._requestResync(channel.key)
		return
	end

	local patches = pendingPatches[channel.key]
	if not patches then
		return
	end

	for _, patch in patches do
		didReceive = channel:receiveUpdate(patch)
		if not didReceive then
			ReplicationClient._requestResync(channel.key)
			break
		end
	end
end

function ReplicationClient._receiveFromStream(id: number, payload: ReplicationShared.Payload, key: string?)
	if key then
		channelKeys[id] = key
	end

	local resolvedKey = channelKeys[id]
	if not resolvedKey then
		warn(`Received a replicator message for unknown id {id}; it was dropped`)
		return
	end

	ReplicationClient._receive(resolvedKey, payload)
end

function ReplicationClient._receive(key: string, payload: ReplicationShared.Payload)
	if payload.kind == "value" then
		ReplicationClient._receiveValue(key, payload :: ReplicationShared.ValuePayload)
	elseif payload.kind == "patch" then
		ReplicationClient._receivePatch(key, payload :: ReplicationShared.PatchPayload)
	end
end

function ReplicationClient._receiveValue(key: string, valuePayload: ReplicationShared.ValuePayload)
	local channel = ChannelRegistry.getChannel(key)
	if channel then
		local didReceive = channel:receive(valuePayload.value)
		if not didReceive then
			return
		end
	else
		-- a full value replaces anything held so far
		latestPayloads[key] = valuePayload
		pendingPatches[key] = nil
	end

	-- a full received value ensures we are no longer out of sync
	resyncingKeys[key] = nil
end

function ReplicationClient._receivePatch(key: string, patchPayload: ReplicationShared.PatchPayload)
	if resyncingKeys[key] ~= nil then
		return
	end

	local channel = ChannelRegistry.getChannel(key)
	if channel then
		local didReceive = channel:receiveUpdate(patchPayload.patch)
		if not didReceive then
			ReplicationClient._requestResync(key)
		end
	else
		-- held until the module is required, then applied after the stored value in arrival order
		local patches = pendingPatches[key]
		if not patches then
			patches = {}
			pendingPatches[key] = patches
		end
		table.insert(patches, patchPayload.patch)
	end
end

function ReplicationClient._startFetch()
	if fetchStarted or not RunService:IsRunning() then
		return
	end
	fetchStarted = true

	task.spawn(function()
		DefineHooks.run(
			ReplicationShared.streamRemote,
			ReplicationShared.STREAM_REMOTE_NAME,
			ReplicationShared.SENCHA_MODULE
		)
		DefineHooks.run(
			ReplicationShared.fetchRemote,
			ReplicationShared.FETCH_REMOTE_NAME,
			ReplicationShared.SENCHA_MODULE
		)
		DefineHooks.run(
			ReplicationShared.resyncRemote,
			ReplicationShared.RESYNC_REMOTE_NAME,
			ReplicationShared.SENCHA_MODULE
		)

		local buffered: { StreamMessage }? = {}
		ReplicationShared.streamRemote:onClientEvent(function(id, payload, key)
			if buffered then
				table.insert(buffered, { id = id, payload = payload, key = key })
			else
				ReplicationClient._receiveFromStream(id, payload, key)
			end
		end)

		local snapshot: ReplicationShared.Snapshot? = nil
		repeat
			local ok, result = ReplicationShared.fetchRemote:invokeServer()
			if ok then
				snapshot = result
			else
				task.wait(FETCH_RETRY_SECONDS)
			end
		until snapshot

		for key, entry in snapshot :: ReplicationShared.Snapshot do
			channelKeys[entry.id] = key
			ReplicationClient._receive(key, entry.payload)
		end

		local pending = buffered :: { StreamMessage }
		buffered = nil
		for _, message in pending do
			ReplicationClient._receiveFromStream(message.id, message.payload, message.key)
		end

		initialFetchComplete:set(true)
	end)
end

function ReplicationClient._requestResync(key: string, attempt: number?)
	local thisAttempt = attempt or 1
	local requestTime = os.clock()
	resyncingKeys[key] = requestTime
	ReplicationShared.resyncRemote:fireServer(key)

	if thisAttempt == RESYNC_WARN_AFTER_ATTEMPTS then
		warn(`Replicator {key} has failed to resync {thisAttempt} times; it will keep retrying with its value frozen`)
	end

	local delay = math.min(RESYNC_BASE_DELAY_SECONDS * 2 ^ (thisAttempt - 1), RESYNC_MAX_DELAY_SECONDS)
	task.delay(delay, function()
		if resyncingKeys[key] == requestTime then
			ReplicationClient._requestResync(key, thisAttempt + 1)
		end
	end)
end

return ReplicationClient

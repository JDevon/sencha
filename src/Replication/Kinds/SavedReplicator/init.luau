local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DefineHooks = require(script.Parent.Parent.Parent.DefineHooks)
local ReplicationShared = require(script.Parent.Parent.ReplicationShared)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.ObservableValue)
local ClientReplicator = require(script.Parent.Parent.ReplicationClient.ClientReplicator)
local ReplicatorChannel = require(script.Parent.Parent.ReplicationShared.ChannelRegistry.ReplicatorChannel)

local toDisconnect = require(script.Parent.Parent.Parent.toDisconnect)
local openChannel = require(script.Parent.Parent.ReplicationShared.openChannel)

--[=[
	@class SavedReplicator

	A read-only view of part of a player's saved data, created with [SavedSource:replicator]. Its value is sent
	only to the player it belongs to.

	To change it, update the saved data; the change replicates when the store calls [SavedSource:replicateChanges].
	This keeps one write path, so an update to several fields at once stays atomic.
]=]
local SavedReplicator = {}
SavedReplicator.__index = SavedReplicator

local function getClientReplicator<D, T, P>(self: SavedReplicator<D, T, P>): ClientReplicator.ClientReplicator<T, P>
	assert(RunService:IsClient(), "SavedReplicator client methods can only be called on the client")
	return assert(self.clientReplicator, "SavedReplicator clientReplicator has not been initialized")
end

export type SavedReplicatorConfig<D, T, P> = {
	kind: string,
	valueType: T,
	lookup: (data: D) -> T,
	getLatestSavedData: (player: Player) -> D?,
	fetchSavedDataAsync: (player: Player) -> D?,
	onChangedForPlayer: (
		key: string,
		callback: (player: Player, newValue: T, oldValue: T) -> ()
	) -> toDisconnect.Disconnect,
	incrementalConfig: ReplicationShared.SavedIncrementalConfig<T, P>?,
}

export type SavedReplicator<D, T, P> = typeof(setmetatable(
	{} :: {
		config: SavedReplicatorConfig<D, T, P>,
		channel: ReplicatorChannel.ReplicatorChannel<T, P>,
		clientReplicator: ClientReplicator.ClientReplicator<T, P>?,
	},
	{} :: {
		__index: {
			get: (self: SavedReplicator<D, T, P>, player: Player?) -> T,
			getAsync: (self: SavedReplicator<D, T, P>, player: Player?) -> T,
			onChanged: (
				self: SavedReplicator<D, T, P>,
				callback: (player: Player, newValue: T, oldValue: T) -> ()
			) -> toDisconnect.Disconnect,
			observe: (self: SavedReplicator<D, T, P>, callback: (value: T) -> ()) -> toDisconnect.Disconnect,
			onUpdateReceived: (
				self: SavedReplicator<D, T, P>,
				callback: (newValue: T, oldValue: T, patch: P) -> ()
			) -> toDisconnect.Disconnect,
			getObservable: (self: SavedReplicator<D, T, P>) -> ObservableValue.ObservableValue<T>,
			isLoaded: (self: SavedReplicator<D, T, P>) -> boolean,
		},
	}
))

-- created through SavedSource:replicator, which types the lookup against the source's saved data
function SavedReplicator.new<D, T, P>(config: SavedReplicatorConfig<D, T, P>): SavedReplicator<D, T, P>
	local self = setmetatable({}, SavedReplicator)
	self.config = config
	self.channel = ReplicatorChannel.new({
		kind = config.kind,
		valueType = config.valueType,
		read = function(_player, data)
			return config.lookup(data)
		end,
		incrementalConfig = config.incrementalConfig,
	})

	if RunService:IsClient() then
		self.clientReplicator = ClientReplicator.new(self.channel)
	end

	DefineHooks.set(self, function(name, parent)
		openChannel(self.channel, name, parent)
	end)

	return self :: any
end

--[=[
	@method get
	@within SavedReplicator

	Returns the current value without yielding. On the server, errors if the player's saved data hasn't loaded yet.

	On the client, errors if the value hasn't arrived yet. Call [Sencha.waitForReplicators] while loading, or use
	[SavedReplicator:getAsync] or [SavedReplicator:observe] in code that may run earlier.

	@param player Player? -- required on the server, left out on the client
	@return T
]=]
function SavedReplicator.get<D, T, P>(self: SavedReplicator<D, T, P>, player: Player?): T
	if RunService:IsServer() then
		assert(player, `SavedReplicator {self.channel.key}:get requires a player on the server`)
		local data = self.config.getLatestSavedData(player)
		if data == nil then
			error(
				`Saved replicator {self.channel.key}:get was called before {player.Name}'s saved data loaded.`
					.. ` Use :getAsync(player) to wait for it.`,
				2
			)
		end
		return self.channel.read(player, data)
	else
		return getClientReplicator(self):get()
	end
end

--[=[
	@method getAsync
	@within SavedReplicator
	@yields

	Returns the current value, yielding until it's available. On the server, waits for the player's saved data to load.

	@param player Player? -- required on the server, left out on the client
	@return T
]=]
function SavedReplicator.getAsync<D, T, P>(self: SavedReplicator<D, T, P>, player: Player?): T
	if RunService:IsServer() then
		assert(player, `SavedReplicator {self.channel.key}:getAsync requires a player on the server`)
		local data = self.config.fetchSavedDataAsync(player)
		assert(data ~= nil, `Saved replicator {self.channel.key} could not read data for player {player.Name}`)
		return self.channel.read(player, data)
	else
		return getClientReplicator(self):getAsync()
	end
end

--[=[
	@method onChanged
	@within SavedReplicator

	Calls `callback` when the value changes, not for the initial value. On the server it fires for any player whose value changes; on the client `player` is always the local player.

	On the server, the change is sent to clients before `callback` runs, so anything it changes in response reaches
	clients after the change that caused it.

	@param callback (player: Player, newValue: T, oldValue: T) -> ()
	@return Disconnect
]=]
function SavedReplicator.onChanged<D, T, P>(
	self: SavedReplicator<D, T, P>,
	callback: (player: Player, newValue: T, oldValue: T) -> ()
)
	if RunService:IsServer() then
		return self.config.onChangedForPlayer(self.channel.key, callback)
	else
		return getClientReplicator(self):onChanged(function(newValue, oldValue)
			callback(Players.LocalPlayer, newValue, oldValue)
		end)
	end
end

--[=[
	@method observe
	@within SavedReplicator
	@client

	Calls `callback` with the current value right away if it has arrived (otherwise when it arrives), then on
	every change.

	@param callback (value: T) -> ()
	@return Disconnect
]=]
function SavedReplicator.observe<D, T, P>(self: SavedReplicator<D, T, P>, callback: (value: T) -> ())
	assert(RunService:IsClient(), `SavedReplicator:observe can only be called on the client`)
	return getClientReplicator(self):observe(callback)
end

--[=[
	@method onUpdateReceived
	@within SavedReplicator
	@client

	Calls `callback` for each patch received, after the value is updated. Only replicators with an incremental
	config receive patches; calling this on one without errors.

	Full values (the first value, a `set`, or a resync) only fire [SavedReplicator:onChanged], so use that to see every
	change.

	@param callback (newValue: T, oldValue: T, patch: P) -> ()
	@return Disconnect
]=]
function SavedReplicator.onUpdateReceived<D, T, P>(
	self: SavedReplicator<D, T, P>,
	callback: (newValue: T, oldValue: T, patch: P) -> ()
)
	assert(RunService:IsClient(), `SavedReplicator:onUpdateReceived can only be called on the client`)
	return getClientReplicator(self):onUpdateReceived(callback)
end

--[=[
	@method getObservable
	@within SavedReplicator
	@client

	Returns an [ObservableValue](https://jdevon.github.io/observable-value/) that follows the replicated value,
	for code that works with ObservableValues, like the
	[ReactObservableValue](https://github.com/JDevon/react-observable-value) hooks. Calling it again returns the same
	one. Setting it doesn't change the replicated value. Errors if the value hasn't arrived yet.

	```lua
	local research = ReactObservableValue.useObservableValue(ResearchNetwork.researchReplicator:getObservable())
	```

	@return ObservableValue<T>
]=]
function SavedReplicator.getObservable<D, T, P>(self: SavedReplicator<D, T, P>): ObservableValue.ObservableValue<T>
	assert(RunService:IsClient(), `SavedReplicator:getObservable can only be called on the client`)
	return getClientReplicator(self):getObservable()
end

--[=[
	@method isLoaded
	@within SavedReplicator
	@client

	Returns whether the value has arrived from the server.

	@return boolean
]=]
function SavedReplicator.isLoaded<D, T, P>(self: SavedReplicator<D, T, P>): boolean
	assert(RunService:IsClient(), `SavedReplicator:isLoaded can only be called on the client`)
	return getClientReplicator(self):isLoaded()
end

return table.freeze({
	new = SavedReplicator.new,
})

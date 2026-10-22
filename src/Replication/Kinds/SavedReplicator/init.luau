local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DefineHooks = require(script.Parent.Parent.Parent.Util.DefineHooks)
local ReplicationShared = require(script.Parent.Parent.ReplicationShared)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.ObservableValue)
local ClientReplicator = require(script.Parent.Parent.ReplicationClient.ClientReplicator)
local PredictionsClient = require(script.Parent.Parent.Parent.Predictions.PredictionsClient)
local ReplicatorChannel = require(script.Parent.Parent.ReplicationShared.ChannelRegistry.ReplicatorChannel)

local toDisconnect = require(script.Parent.Parent.Parent.Util.toDisconnect)
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
			observe: (
				self: SavedReplicator<D, T, P>,
				callback: (newValue: T, oldValue: T?) -> ()
			) -> toDisconnect.Disconnect,
			onUpdateReceived: (
				self: SavedReplicator<D, T, P>,
				callback: (newValue: T, oldValue: T, patch: P) -> ()
			) -> toDisconnect.Disconnect,
			getObservable: (self: SavedReplicator<D, T, P>) -> ObservableValue.ObservableValue<T>,
			getConfirmed: (self: SavedReplicator<D, T, P>) -> T,
			onConfirmedChanged: (
				self: SavedReplicator<D, T, P>,
				callback: (player: Player, newValue: T, oldValue: T) -> ()
			) -> toDisconnect.Disconnect,
			prediction: (
				self: SavedReplicator<D, T, P>,
				predict: ((value: T) -> T) | P
			) -> PredictionsClient.PredictionRequest,
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

	On the client, this includes pending predictions. [SavedReplicator:getConfirmed] returns the server's value
	without them.

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

	On the client, this includes pending predictions. [SavedReplicator:getConfirmed] returns the server's value
	without them.

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

	Calls `callback` when the value changes, not for the initial value. On the server this fires for any player whose
	value changes; on the client `player` is always the local player.

	On the server, the change is sent to clients before `callback` runs, so anything it changes in response reaches
	clients after the change that caused it.

	On the client, this also fires when a prediction is made, and again if it's rolled back. Use
	[SavedReplicator:onConfirmedChanged] to only hear about the server's changes.

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
	every change. `oldValue` is the value before the change, or `nil` for the first call.

	```lua
	ResearchNetwork.researchReplicator:observe(function(research, oldResearch)
		print(`researched {#research} items, up from {if oldResearch then #oldResearch else 0}`)
	end)
	```

	This includes predictions: it fires when a prediction is made, and again if it's rolled back.

	@param callback (newValue: T, oldValue: T?) -> ()
	@return Disconnect
]=]
function SavedReplicator.observe<D, T, P>(self: SavedReplicator<D, T, P>, callback: (newValue: T, oldValue: T?) -> ())
	assert(RunService:IsClient(), `SavedReplicator:observe can only be called on the client`)
	return getClientReplicator(self):observe(callback)
end

--[=[
	@method onUpdateReceived
	@within SavedReplicator
	@client

	Calls `callback` for each patch received, after the value is updated. Only replicators with an incremental
	config receive patches; calling this on one without errors.

	The first value is a whole value, so it doesn't fire this; use [SavedReplicator:onChanged] to see every change.

	Patches always come from the server: predictions don't fire this, and `newValue` and `oldValue` are the
	server's values.

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
	[ReactObservableValue](https://github.com/JDevon/react-observable-value) hooks. Calling this again returns the same
	one. Setting it doesn't change the replicated value. Errors if the value hasn't arrived yet.

	```lua
	local research = ReactObservableValue.useObservableValue(ResearchNetwork.researchReplicator:getObservable())
	```

	The observable includes pending predictions, like [SavedReplicator:get].

	@return ObservableValue<T>
]=]
function SavedReplicator.getObservable<D, T, P>(self: SavedReplicator<D, T, P>): ObservableValue.ObservableValue<T>
	assert(RunService:IsClient(), `SavedReplicator:getObservable can only be called on the client`)
	return getClientReplicator(self):getObservable()
end

--[=[
	@method getConfirmed
	@within SavedReplicator
	@client

	Returns the value the server sent, without any pending predictions. [SavedReplicator:get] returns the predicted
	value while a prediction is pending; use this when code must only act on what the server has confirmed. Errors if
	the value hasn't arrived yet.

	@return T
]=]
function SavedReplicator.getConfirmed<D, T, P>(self: SavedReplicator<D, T, P>): T
	assert(RunService:IsClient(), `SavedReplicator:getConfirmed can only be called on the client`)
	return getClientReplicator(self):getConfirmed()
end

--[=[
	@method onConfirmedChanged
	@within SavedReplicator
	@client

	Calls `callback` when the server's value changes, not for predictions or the initial value. `player` is always the
	local player.

	[SavedReplicator:onChanged] also fires for predictions, and again if a wrong prediction is rolled back. Use this
	instead for effects that should only change for confirmed values:

	```lua
	ResearchNetwork.researchReplicator:onConfirmedChanged(function(_player, research, oldResearch)
		print(`the server confirmed {#research} researched items`)
	end)
	```

	@param callback (player: Player, newValue: T, oldValue: T) -> ()
	@return Disconnect
]=]
function SavedReplicator.onConfirmedChanged<D, T, P>(
	self: SavedReplicator<D, T, P>,
	callback: (player: Player, newValue: T, oldValue: T) -> ()
): toDisconnect.Disconnect
	assert(RunService:IsClient(), `SavedReplicator:onConfirmedChanged can only be called on the client`)
	return getClientReplicator(self):onConfirmedChanged(function(newValue, oldValue)
		callback(Players.LocalPlayer, newValue, oldValue)
	end)
end

--[=[
	@method prediction
	@within SavedReplicator
	@client

	Builds a prediction for this replicator. The returned prediction can be used with a predicted remote call such as
	`invokeServerPredicted` or `fireServerPredicted`. While the call is pending, [SavedReplicator:get],
	[SavedReplicator:observe] and [SavedReplicator:onChanged] show the value with the prediction applied; it's removed
	when the server confirms the call.

	`predict` is either a function that returns the predicted value, or a patch on a replicator with an incremental
	config. A patch is applied with the config's `apply`, the same way the server's patches are.

	```lua
	ResearchNetwork.researchRemote:invokeServerPredicted({
		ResearchNetwork.researchReplicator:prediction(function(research)
			local newResearch = table.clone(research)
			table.insert(newResearch, "drills")
			return newResearch
		end),
	}, "drills")
	```

	@param predict ((value: T) -> T) | P
	@return Prediction
]=]
function SavedReplicator.prediction<D, T, P>(
	self: SavedReplicator<D, T, P>,
	predict: ((value: T) -> T) | P
): PredictionsClient.PredictionRequest
	assert(RunService:IsClient(), `SavedReplicator:prediction can only be called on the client`)
	return getClientReplicator(self):prediction(predict)
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

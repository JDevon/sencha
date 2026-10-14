local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Parent.Parent.Parent.Signal)
local DefineHooks = require(script.Parent.Parent.Parent.Parent.Util.DefineHooks)
local ReplicationServer = require(script.Parent.Parent.Parent.ReplicationServer)
local ReplicationShared = require(script.Parent.Parent.Parent.ReplicationShared)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.Parent.ObservableValue)
local ClientReplicator = require(script.Parent.Parent.Parent.ReplicationClient.ClientReplicator)
local ReplicatorChannel = require(script.Parent.Parent.Parent.ReplicationShared.ChannelRegistry.ReplicatorChannel)

local noYielding = require(script.Parent.Parent.Parent.Parent.Util.noYielding)
local toDisconnect = require(script.Parent.Parent.Parent.Parent.Util.toDisconnect)
local openChannel = require(script.Parent.Parent.Parent.ReplicationShared.openChannel)

local KIND = "temporaryPlayer"

--[=[
	@class TemporaryPlayerReplicator

	One value per player that the server keeps in memory, created with `Sencha.temporaryReplicator.player`. Each
	player's value is sent only to that player, starts as the default value, and is cleared when they leave.
]=]
local TemporaryPlayerReplicator = {}
TemporaryPlayerReplicator.__index = TemporaryPlayerReplicator

local function getClientReplicator<T, P>(self: TemporaryPlayerReplicator<T, P>): ClientReplicator.ClientReplicator<T, P>
	assert(RunService:IsClient(), "TemporaryPlayerReplicator client methods can only be called on the client")
	return assert(self.clientReplicator, "TemporaryPlayerReplicator clientReplicator has not been initialized")
end

local function readValue(self: any, player: Player): any
	local stored = self.values[player]
	if stored then
		return stored.value
	end
	return self.defaultValue
end

export type TemporaryPlayerReplicator<T, P> = typeof(setmetatable(
	{} :: {
		channel: ReplicatorChannel.ReplicatorChannel<T, P>,
		defaultValue: T,
		-- values are wrapped so a player explicitly set to nil is told apart from one using the default
		values: { [Player]: { value: T } },
		clientReplicator: ClientReplicator.ClientReplicator<T, P>?,
		serverChangedSignal: Signal.Signal<Player, T, T>?,
	},
	{} :: {
		__index: {
			get: (self: TemporaryPlayerReplicator<T, P>, player: Player?) -> T,
			getAsync: (self: TemporaryPlayerReplicator<T, P>, player: Player?) -> T,
			set: (self: TemporaryPlayerReplicator<T, P>, player: Player, value: T) -> (),
			tryUpdate: (
				self: TemporaryPlayerReplicator<T, P>,
				player: Player,
				callback: (value: T) -> (boolean, T?)
			) -> boolean,
			applyIncrementalUpdate: (self: TemporaryPlayerReplicator<T, P>, player: Player, update: P) -> (),
			observe: (self: TemporaryPlayerReplicator<T, P>, callback: (value: T) -> ()) -> toDisconnect.Disconnect,
			onUpdateReceived: (
				self: TemporaryPlayerReplicator<T, P>,
				callback: (newValue: T, oldValue: T, patch: P) -> ()
			) -> toDisconnect.Disconnect,
			onChanged: (
				self: TemporaryPlayerReplicator<T, P>,
				callback: (player: Player, newValue: T, oldValue: T) -> ()
			) -> toDisconnect.Disconnect,
			getObservable: (self: TemporaryPlayerReplicator<T, P>) -> ObservableValue.ObservableValue<T>,
			isLoaded: (self: TemporaryPlayerReplicator<T, P>) -> boolean,
		},
	}
))

function TemporaryPlayerReplicator.new<T, P>(
	valueType: T,
	defaultValue: T,
	incrementalConfig: ReplicationShared.TemporaryIncrementalConfig<T, P>?
): TemporaryPlayerReplicator<T, P>
	if incrementalConfig and (incrementalConfig :: any).diff ~= nil then
		error("Temporary replicators don't use diff; send patches with applyIncrementalUpdate", 2)
	end

	local self = setmetatable({}, TemporaryPlayerReplicator) :: any
	self.values = {}
	self.channel = ReplicatorChannel.new({
		kind = KIND,
		valueType = valueType,
		read = function(player)
			return readValue(self, player)
		end,
		incrementalConfig = incrementalConfig,
	})
	self.defaultValue = self.channel:prepareValue(defaultValue)

	if RunService:IsClient() then
		self.clientReplicator = ClientReplicator.new(self.channel)
	end

	if RunService:IsServer() then
		self.serverChangedSignal = Signal.new()
	end

	if RunService:IsServer() and RunService:IsRunning() then
		-- clearing a leaving player's value is cleanup, not a change, so it does not fire onChanged
		Players.PlayerRemoving:Connect(function(player)
			self.values[player] = nil
		end)
	end

	DefineHooks.set(self, function(name, parent)
		openChannel(self.channel, name, parent)
	end)

	return self
end

--[=[
	@method get
	@within TemporaryPlayerReplicator

	Returns the current value without yielding.

	On the client, errors if the value hasn't arrived yet. Call [Sencha.waitForReplicators] while loading, or use
	[TemporaryPlayerReplicator:getAsync] or [TemporaryPlayerReplicator:observe] in code that may run earlier.

	@param player Player? -- required on the server, left out on the client
	@return T
]=]
function TemporaryPlayerReplicator.get<T, P>(self: TemporaryPlayerReplicator<T, P>, player: Player?): T
	if RunService:IsServer() then
		assert(player, `TemporaryPlayerReplicator {self.channel.key}:get requires a player on the server`)
		return readValue(self, player)
	else
		return getClientReplicator(self):get()
	end
end

--[=[
	@method getAsync
	@within TemporaryPlayerReplicator
	@yields

	Returns the current value, yielding until it's available. Server values always exist, so this only yields on the
	client.

	@param player Player? -- required on the server, left out on the client
	@return T
]=]
function TemporaryPlayerReplicator.getAsync<T, P>(self: TemporaryPlayerReplicator<T, P>, player: Player?): T
	if RunService:IsServer() then
		assert(player, `TemporaryPlayerReplicator {self.channel.key}:getAsync requires a player on the server`)
		return readValue(self, player)
	else
		return getClientReplicator(self):getAsync()
	end
end

--[=[
	@method set
	@within TemporaryPlayerReplicator
	@server

	Sets a player's value and sends it to them. Errors if the value doesn't match the replicator's type. Setting
	a primitive to the value it already has does nothing; setting a table always counts as a change.

	@param player Player
	@param value T
]=]
function TemporaryPlayerReplicator.set<T, P>(self: TemporaryPlayerReplicator<T, P>, player: Player, value: T)
	assert(RunService:IsServer(), `TemporaryPlayerReplicator:set can only be called on the server`)
	local preparedValue = self.channel:prepareValue(value)
	if player.Parent == nil then
		return
	end

	local oldValue = readValue(self, player)
	if preparedValue == oldValue then
		return
	end

	-- stored first so listeners calling get(player) see the new value; clients are sent the change before
	-- server listeners run, so anything a listener changes in response reaches clients after it
	self.values[player] = { value = preparedValue }
	local payload = ReplicationServer.createPayload(self.channel, preparedValue, "value")
	ReplicationServer.publish(self.channel, player, payload)
	assert(self.serverChangedSignal, "TemporaryPlayerReplicator serverChangedSignal has not been initialized"):Fire(
		player,
		preparedValue,
		oldValue
	)
end

--[=[
	@method tryUpdate
	@within TemporaryPlayerReplicator
	@server

	Calls `callback` with a player's current value. If it returns `true` and a new value, the value is set as with
	[TemporaryPlayerReplicator:set]; if it returns `false`, nothing changes. Returns what `callback` returned first.

	`callback` must not yield, so nothing else can change the value between reading and setting it.

	```lua
	local didBuy = CurrencyNetwork.coinsReplicator:tryUpdate(player, function(coins)
		if coins < 10 then
			return false
		end
		return true, coins - 10
	end)
	```

	@param player Player
	@param callback (value: T) -> (boolean, T?)
	@return boolean
]=]
function TemporaryPlayerReplicator.tryUpdate<T, P>(
	self: TemporaryPlayerReplicator<T, P>,
	player: Player,
	callback: (value: T) -> (boolean, T?)
): boolean
	assert(RunService:IsServer(), `TemporaryPlayerReplicator:tryUpdate can only be called on the server`)
	local shouldSet, newValue = noYielding(callback, readValue(self, player))
	if not shouldSet then
		return false
	end

	self:set(player, newValue :: T)
	return true
end

--[=[
	@method applyIncrementalUpdate
	@within TemporaryPlayerReplicator
	@server

	Applies `patch` to a player's value with the incremental config's `apply`, then sends only the patch to them.
	Errors if the patch or the new value doesn't match its type, or if the replicator has no incremental config. An
	empty table patch does nothing.

	@param player Player
	@param patch P
]=]
function TemporaryPlayerReplicator.applyIncrementalUpdate<T, P>(
	self: TemporaryPlayerReplicator<T, P>,
	player: Player,
	update: P
)
	assert(RunService:IsServer(), `TemporaryPlayerReplicator:applyIncrementalUpdate can only be called on the server`)
	assert(
		self.channel.incrementalConfig,
		`TemporaryPlayerReplicator {self.channel.key} does not have an incremental config`
	)

	if type(update) == "table" and next(update :: any) == nil then
		return
	end

	local oldValue = readValue(self, player)
	local newValue, patchFailure = self.channel:applyPatch(oldValue, update)
	if not newValue then
		error(patchFailure, 2)
	end

	if newValue == oldValue or player.Parent == nil then
		return
	end

	self.values[player] = { value = newValue }
	local payload = ReplicationServer.createPayload(self.channel, update, "patch")
	ReplicationServer.publish(self.channel, player, payload)
	assert(self.serverChangedSignal, "TemporaryPlayerReplicator serverChangedSignal has not been initialized"):Fire(
		player,
		newValue,
		oldValue
	)
end

--[=[
	@method onChanged
	@within TemporaryPlayerReplicator

	Calls `callback` when the value changes, not for the initial value. On the server this fires for any player whose
	value changes; on the client `player` is always the local player.

	On the server, the change is sent to clients before `callback` runs, so anything it changes in response reaches
	clients after the change that caused it.

	@param callback (player: Player, newValue: T, oldValue: T) -> ()
	@return Disconnect
]=]
function TemporaryPlayerReplicator.onChanged<T, P>(
	self: TemporaryPlayerReplicator<T, P>,
	callback: (player: Player, newValue: T, oldValue: T) -> ()
)
	if RunService:IsServer() then
		return toDisconnect(assert(
			self.serverChangedSignal,
			"TemporaryPlayerReplicator serverChangedSignal has not been initialized"
		):Connect(callback))
	else
		return getClientReplicator(self):onChanged(function(newValue, oldValue)
			callback(Players.LocalPlayer, newValue, oldValue)
		end)
	end
end

--[=[
	@method observe
	@within TemporaryPlayerReplicator
	@client

	Calls `callback` with the current value right away if it has arrived (otherwise when it arrives), then on
	every change.

	@param callback (value: T) -> ()
	@return Disconnect
]=]
function TemporaryPlayerReplicator.observe<T, P>(self: TemporaryPlayerReplicator<T, P>, callback: (value: T) -> ())
	assert(RunService:IsClient(), `TemporaryPlayerReplicator:observe can only be called on the client`)
	return getClientReplicator(self):observe(callback)
end

--[=[
	@method onUpdateReceived
	@within TemporaryPlayerReplicator
	@client

	Calls `callback` for each patch received, after the value is updated. Only replicators with an incremental
	config receive patches; calling this on one without errors.

	Whole values (the first value, a `set`, or a resync) don't fire this; use
	[TemporaryPlayerReplicator:onChanged] to see every change.

	@param callback (newValue: T, oldValue: T, patch: P) -> ()
	@return Disconnect
]=]
function TemporaryPlayerReplicator.onUpdateReceived<T, P>(
	self: TemporaryPlayerReplicator<T, P>,
	callback: (newValue: T, oldValue: T, patch: P) -> ()
)
	assert(RunService:IsClient(), `TemporaryPlayerReplicator:onUpdateReceived can only be called on the client`)
	return getClientReplicator(self):onUpdateReceived(callback)
end

--[=[
	@method getObservable
	@within TemporaryPlayerReplicator
	@client

	Returns an [ObservableValue](https://jdevon.github.io/observable-value/) that follows the replicated value,
	for code that works with ObservableValues, like the
	[ReactObservableValue](https://github.com/JDevon/react-observable-value) hooks. Calling this again returns the same
	one. Setting it doesn't change the replicated value. Errors if the value hasn't arrived yet.

	```lua
	local coins = ReactObservableValue.useObservableValue(CurrencyNetwork.coinsReplicator:getObservable())
	```

	@return ObservableValue<T>
]=]
function TemporaryPlayerReplicator.getObservable<T, P>(self: TemporaryPlayerReplicator<T, P>): ObservableValue.ObservableValue<T>
	assert(RunService:IsClient(), `TemporaryPlayerReplicator:getObservable can only be called on the client`)
	return getClientReplicator(self):getObservable()
end

--[=[
	@method isLoaded
	@within TemporaryPlayerReplicator
	@client

	Returns whether the value has arrived from the server.

	@return boolean
]=]
function TemporaryPlayerReplicator.isLoaded<T, P>(self: TemporaryPlayerReplicator<T, P>): boolean
	assert(RunService:IsClient(), `TemporaryPlayerReplicator:isLoaded can only be called on the client`)
	return getClientReplicator(self):isLoaded()
end

return table.freeze({
	new = TemporaryPlayerReplicator.new,
})

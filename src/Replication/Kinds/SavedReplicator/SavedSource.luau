local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SavedReplicator = require(script.Parent)
local Signal = require(script.Parent.Parent.Parent.Parent.Parent.Signal)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.Parent.ObservableValue)
local ChannelRegistry = require(script.Parent.Parent.Parent.ReplicationShared.ChannelRegistry)
local ReplicationShared = require(script.Parent.Parent.Parent.Parent.Replication.ReplicationShared)
local ReplicationServer = require(script.Parent.Parent.Parent.Parent.Replication.ReplicationServer)

local toDisconnect = require(script.Parent.Parent.Parent.Parent.Util.toDisconnect)

type FetchAsync<D> = (player: Player) -> D?

-- a built GreenTea type; only its type field is read for typing, so `matches` isn't part of this shape
export type SavedDataType<D> = { __getType: () -> D }

export type SavedSource<D> = typeof(setmetatable(
	{} :: {
		name: string,
		kind: string,
		savedDataType: SavedDataType<D>,
		fetchAsyncObservable: ObservableValue.ObservableValue<FetchAsync<D>?>,
		latestSavedData: { [Player]: D },
		changedForPlayerSignals: { [string]: Signal.Signal<Player, any, any> },
		hasReportedInvalidSavedData: boolean,
	},
	{} :: {
		__index: {
			replicator: <T, P>(
				self: SavedSource<D>,
				valueType: T,
				lookup: (savedData: D) -> T,
				incrementalConfig: ReplicationShared.SavedIncrementalConfig<T, P>?
			) -> SavedReplicator.SavedReplicator<D, T, P>,
			setFetchFunction: (self: SavedSource<D>, fetchAsync: FetchAsync<D>) -> (),
			replicateChanges: (self: SavedSource<D>, player: Player, newData: D, oldData: D?) -> (),
			getLatestSavedData: (self: SavedSource<D>, player: Player) -> D?,
			fetchSavedDataAsync: (self: SavedSource<D>, player: Player) -> D?,
			onChangedForPlayer: (
				self: SavedSource<D>,
				key: string,
				callback: (player: Player, newValue: any, oldValue: any) -> ()
			) -> toDisconnect.Disconnect,
		},
	}
))

local sourcesByName: { [string]: true } = {}

--[=[
	@class SavedSource

	One store of saved player data, such as a DataStore wrapper, created with [Sencha.savedSource]. Saved
	replicators are created from it, and the server connects it to the store with
	[SavedSource:setFetchFunction] and [SavedSource:replicateChanges].

	Sencha doesn't depend on any data store library. A game with two stores creates two sources, and they never
	interfere.

	In Studio, the source's GreenTea type also checks the data it receives, and warns once if it doesn't match.
]=]
local SavedSource = {}
SavedSource.__index = SavedSource

local function validateSavedData(self: any, data: any, from: string)
	if not RunService:IsStudio() or self.hasReportedInvalidSavedData or data == nil then
		return
	end

	local ok, cause = self.savedDataType:matches(data)
	if not ok then
		-- reported once, every other later save would fail the same way
		self.hasReportedInvalidSavedData = true
		warn(`Saved source {self.name} received data from {from} that does not match its type:\n{cause:formatErr()}`)
	end
end

function SavedSource.new<D>(name: string, savedDataType: SavedDataType<D>): SavedSource<D>
	if sourcesByName[name] then
		error(`A saved source named {name} already exists; each store needs its own name`, 3)
	end
	sourcesByName[name] = true

	local self = setmetatable({}, SavedSource) :: any
	self.name = name
	self.kind = `saved:{name}`
	self.savedDataType = savedDataType
	self.fetchAsyncObservable = ObservableValue.new(nil :: FetchAsync<D>?)
	self.latestSavedData = {}
	self.changedForPlayerSignals = {}
	self.hasReportedInvalidSavedData = false

	if RunService:IsServer() then
		Players.PlayerRemoving:Connect(function(player)
			self.latestSavedData[player] = nil
		end)

		-- snapshots read from this store's data, which may still be loading
		ReplicationServer.setSnapshotPreparer(self.kind, function(player)
			local data = self:fetchSavedDataAsync(player)
			return data ~= nil, data
		end)
	end

	return self
end

--[=[
	@method replicator
	@within SavedSource

	Creates a [SavedReplicator] for the part of the saved data that `lookup` returns. The saved data passed to
	`lookup` is fully typed from the source's GreenTea type.

	```lua
	researchReplicator = PlayerDataSource:replicator(gt.array(gt.string()), function(playerData)
		return playerData.research
	end),
	```

	`lookup` must return an existing table from the saved data, or a primitive, and must not yield. Changes are
	found by comparing what it returns, so a lookup that builds a new table counts as changed on every save.

	@param valueType GreenTeaType
	@param lookup (savedData: D) -> T
	@param incrementalConfig SavedIncrementalConfig<T, P>?
	@return SavedReplicator<D, T, P>
]=]
function SavedSource.replicator<D, T, P>(
	self: SavedSource<D>,
	valueType: T,
	lookup: (savedData: D) -> T,
	incrementalConfig: ReplicationShared.SavedIncrementalConfig<T, P>?
): SavedReplicator.SavedReplicator<D, T, P>
	if incrementalConfig then
		assert(incrementalConfig.diff, `Saved replicators need a diff function in their incremental config`)
	end

	return SavedReplicator.new({
		kind = self.kind,
		valueType = valueType,
		lookup = lookup,
		getLatestSavedData = function(player: Player): D?
			return self:getLatestSavedData(player)
		end,
		fetchSavedDataAsync = function(player: Player): D?
			return self:fetchSavedDataAsync(player)
		end,
		onChangedForPlayer = function(key: string, callback: (player: Player, newValue: T, oldValue: T) -> ())
			return self:onChangedForPlayer(key, callback)
		end,
		incrementalConfig = incrementalConfig,
	})
end

--[=[
	@method setFetchFunction
	@within SavedSource
	@server

	Sets the function that returns a player's saved data, yielding until it has loaded, or `nil` if it never loads.
	Replicators from this source wait for it to be set.

	```lua
	PlayerDataSource:setFetchFunction(function(player)
		local didLoad, playerData = PlayerDataServer.waitForPlayerData(player)
		return if didLoad then playerData else nil
	end)
	```

	@param fetchAsync (player: Player) -> D?
]=]
function SavedSource.setFetchFunction<D>(self: SavedSource<D>, fetchAsync: FetchAsync<D>)
	assert(RunService:IsServer(), `SavedSource {self.name}:setFetchFunction can only be called on the server`)
	self.fetchAsyncObservable:set(fetchAsync)
end

--[=[
	@method replicateChanges
	@within SavedSource
	@server

	Tells the source that a player's saved data changed, including when it first loads (`oldData` is `nil`). Each
	replicator whose part changed sends it to the player, then fires its `onChanged`. Call this from your store's
	change callback.

	```lua
	PlayerDataSource:replicateChanges(player, newData, oldData)
	```

	@param player Player
	@param newData D
	@param oldData D?
]=]
function SavedSource.replicateChanges<D>(self: SavedSource<D>, player: Player, newData: D, oldData: D?)
	assert(RunService:IsServer(), `SavedSource {self.name}:replicateChanges can only be called on the server`)
	validateSavedData(self, newData, "replicateChanges")
	self.latestSavedData[player] = newData
	if oldData == nil then
		return
	end

	for key, channel in pairs(ChannelRegistry.getChannels()) do
		if channel.kind ~= self.kind then
			continue
		end

		local newValue = channel.read(player, newData)
		local oldValue = channel.read(player, oldData)
		if newValue == oldValue then
			continue
		end

		if channel.incrementalConfig then
			local savedIncrementalConfig =
				channel.incrementalConfig :: ReplicationShared.SavedIncrementalConfig<any, any>
			local diff = savedIncrementalConfig.diff(newValue, oldValue)
			if diff ~= nil and not (type(diff) == "table" and next(diff) == nil) then
				local validatedPayload = ReplicationServer.getValidatedPayload(channel, diff, "patch")
				if validatedPayload then
					ReplicationServer.publish(channel, player, validatedPayload)
				end
			end
		else
			local validatedPayload = ReplicationServer.getValidatedPayload(channel, newValue, "value")
			if validatedPayload then
				ReplicationServer.publish(channel, player, validatedPayload)
			end
		end

		local signal = self.changedForPlayerSignals[key]
		if signal then
			signal:Fire(player, newValue, oldValue)
		end
	end
end

function SavedSource.getLatestSavedData<D>(self: SavedSource<D>, player: Player): D?
	return self.latestSavedData[player]
end

function SavedSource.fetchSavedDataAsync<D>(self: SavedSource<D>, player: Player): D?
	local fetchAsync = self.fetchAsyncObservable
		:promiseValue(function(setFetchAsync)
			return setFetchAsync ~= nil, setFetchAsync
		end)
		:expect() :: FetchAsync<D>
	local fetched = fetchAsync(player)
	validateSavedData(self, fetched, "the fetch function")
	self.latestSavedData[player] = fetched :: D
	return fetched
end

function SavedSource.onChangedForPlayer<D>(
	self: SavedSource<D>,
	key: string,
	callback: (player: Player, newValue: any, oldValue: any) -> ()
): toDisconnect.Disconnect
	local signal = self.changedForPlayerSignals[key]
	if not signal then
		signal = Signal.new()
		self.changedForPlayerSignals[key] = signal
	end
	return toDisconnect(signal:Connect(callback))
end

return table.freeze({
	new = SavedSource.new,
})

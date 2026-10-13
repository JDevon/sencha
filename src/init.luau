local RunService = game:GetService("RunService")

local DefineHooks = require(script.DefineHooks)
local RateLimiter = require(script.Remotes.RateLimiter)

local RemoteEvent = require(script.Remotes.Kinds.RemoteEvent)
local RemoteFunction = require(script.Remotes.Kinds.RemoteFunction)
local RemoteFnSwitchboard = require(script.Remotes.Kinds.RemoteFnSwitchboard)
local RemoteEventSwitchboard = require(script.Remotes.Kinds.RemoteEventSwitchboard)

local ReplicationShared = require(script.Replication.ReplicationShared)
local ReplicationClient = require(script.Replication.ReplicationClient)
local SavedReplicator = require(script.Replication.Kinds.SavedReplicator)
local SavedSource = require(script.Replication.Kinds.SavedReplicator.SavedSource)
local TemporaryReplicator = require(script.Replication.Kinds.TemporaryReplicator)
local TemporaryPlayerReplicator = require(script.Replication.Kinds.TemporaryReplicator.TemporaryPlayerReplicator)
local TemporaryGlobalReplicator = require(script.Replication.Kinds.TemporaryReplicator.TemporaryGlobalReplicator)

local toDisconnect = require(script.toDisconnect)

--[=[
	@type Disconnect () -> ()
	@within Sencha

	Every listener method returns a `Disconnect`, the cleanup function. Call it to stop listening. It's safe to call
	more than once, and can be handed to a cleanup library or returned from a React effect.
]=]
export type Disconnect = toDisconnect.Disconnect

--[=[
	@interface Limit
	@within Sencha
	.burst number -- calls a player can make at once; at least 1
	.perSecond number -- calls a player gets back each second; more than 0

	A rate limit for calls from clients, passed to `:rateLimit(...)` on any remote. Each player has their own budget.
]=]
export type Limit = RateLimiter.Limit

--[=[
	@interface TemporaryIncrementalConfig
	@within Sencha
	.patchType GreenTeaType -- the GreenTea type of a patch
	.apply (value: T, patch: P) -> T -- returns the value with the patch applied; runs on the server and the client

	Makes a temporary replicator send patches with `applyIncrementalUpdate` instead of sending the whole value.
]=]
export type TemporaryIncrementalConfig<T, P> = ReplicationShared.TemporaryIncrementalConfig<T, P>

--[=[
	@interface SavedIncrementalConfig
	@within Sencha
	.patchType GreenTeaType -- the GreenTea type of a patch
	.diff (newValue: T, oldValue: T) -> P -- returns a patch describing what changed; runs on the server
	.apply (value: T, patch: P) -> T -- returns the value with the patch applied; runs on the server and the client

	Makes a saved replicator send patches instead of the whole value when the saved data changes.
]=]
export type SavedIncrementalConfig<T, P> = ReplicationShared.SavedIncrementalConfig<T, P>

export type Event<T...> = RemoteEvent.Event<T...>
export type Function<T..., R...> = RemoteFunction.Function<T..., R...>
export type EventSwitchboard<T...> = RemoteEventSwitchboard.RemoteEventSwitchboard<T...>
export type FunctionSwitchboard<T..., R...> = RemoteFnSwitchboard.RemoteFnSwitchboard<T..., R...>
export type SavedSource<D> = SavedSource.SavedSource<D>
export type SavedReplicator<D, T, P> = SavedReplicator.SavedReplicator<D, T, P>
export type TemporaryPlayerReplicator<T, P> = TemporaryPlayerReplicator.TemporaryPlayerReplicator<T, P>
export type TemporaryGlobalReplicator<T, P> = TemporaryGlobalReplicator.TemporaryGlobalReplicator<T, P>

--[=[
	@class Sencha

	Typed remotes and server-owned state for Roblox. Define remotes and replicators together in one shared module
	with [Sencha.define], and require it on the server and the client.

	```lua
	-- ReplicatedStorage/CurrencyNetwork.luau
	local Sencha = require(ReplicatedStorage.Packages.Sencha)
	local gt = require(ReplicatedStorage.Packages.GreenTea)

	return Sencha.define(script, {
		buyItemRemote = Sencha.func(gt.args(gt.string()), gt.returns(gt.boolean())),
		coinsReplicator = Sencha.temporaryReplicator.player(gt.number(), 0),
	})
	```
]=]
local Sencha = {}

--[=[
	@function event
	@within Sencha

	Creates an [Event], a typed `RemoteEvent`. Arguments are checked against the GreenTea types on both sides.

	```lua
	damageEvent = Sencha.event(gt.number(), gt.Vector3()),
	```

	@param ... GreenTeaType -- the type of each argument
	@return Event<T...>
]=]
Sencha.event = RemoteEvent.new

--[=[
	@function unreliableEvent
	@within Sencha

	Creates an [Event] backed by an `UnreliableRemoteEvent`. It has the same API as [Sencha.event], but messages
	may be dropped or arrive out of order, and payloads are limited to roughly 900 bytes. Use it for repeating
	updates where only the latest matters, never for messages that must arrive.

	@param ... GreenTeaType -- the type of each argument
	@return Event<T...>
]=]
Sencha.unreliableEvent = RemoteEvent.newUnreliable

--[=[
	@function func
	@within Sencha

	Creates a [Function], a typed `RemoteFunction` the client invokes on the server.

	```lua
	buyItemRemote = Sencha.func(gt.args(gt.string()), gt.returns(gt.boolean())),
	```

	@param args GreenTeaArgs -- `gt.args(...)`
	@param returns GreenTeaReturns -- `gt.returns(...)`
	@return Function<T..., R...>
]=]
Sencha.func = RemoteFunction.new

--[=[
	@function eventSwitchboard
	@within Sencha

	Creates an [EventSwitchboard]: one `RemoteEvent` that routes client calls to a server callback by port name.

	@param ... GreenTeaType -- the type of each argument after the port
	@return EventSwitchboard<T...>
]=]
Sencha.eventSwitchboard = RemoteEventSwitchboard.new

--[=[
	@function funcSwitchboard
	@within Sencha

	Creates a [FunctionSwitchboard]: one `RemoteFunction` that routes client calls to a server callback by port
	name.

	@param args GreenTeaArgs -- `gt.args(...)`
	@param returns GreenTeaReturns -- `gt.returns(...)`
	@return FunctionSwitchboard<T..., R...>
]=]
Sencha.funcSwitchboard = RemoteFnSwitchboard.new

--[=[
	@prop temporaryReplicator { player: (valueType, defaultValue, incrementalConfig?) -> TemporaryPlayerReplicator, global: (valueType, initialValue, incrementalConfig?) -> TemporaryGlobalReplicator }
	@within Sencha

	Creates replicators for state the server keeps in memory.

	- `temporaryReplicator.player` creates a [TemporaryPlayerReplicator]: one value per player, sent only to
	  that player.
	- `temporaryReplicator.global` creates a [TemporaryGlobalReplicator]: one value, sent to every player.

	```lua
	carriedOreReplicator = Sencha.temporaryReplicator.player(gt.number(), 0),
	meteorShowerReplicator = Sencha.temporaryReplicator.global(gt.boolean(), false),
	```
]=]
Sencha.temporaryReplicator = TemporaryReplicator

--[=[
	@within Sencha

	Creates a [SavedSource] for one store of saved player data. Create one per store in a shared module, then
	create replicators from it with [SavedSource:replicator].

	```lua
	-- ReplicatedStorage/PlayerDataSource.luau
	return Sencha.savedSource("PlayerData", PlayerDataTypes.PlayerData)
	```

	@param name string -- a name unique to this store
	@param savedDataType GreenTeaType -- the built GreenTea type of the saved data
	@return SavedSource<D>
]=]
function Sencha.savedSource<D>(name: string, savedDataType: SavedSource.SavedDataType<D>): SavedSource.SavedSource<D>
	return SavedSource.new(name, savedDataType)
end

--[=[
	@within Sencha

	Names and sets up every remote and replicator in `implementations` from its key, and returns the same table.
	Remotes are created under `parent`, and each replicator's name is `parent:GetFullName()` plus its key, so the
	same module resolves to the same remotes and replicators on both sides.

	Each remote and replicator can only be defined once.

	@param parent Instance -- usually `script`
	@param implementations T -- a table of remotes and replicators
	@return T
]=]
function Sencha.define<T>(parent: Instance, implementations: T): T
	for name, implementation in implementations :: any do
		DefineHooks.run(implementation, name, parent)
	end
	return implementations
end

--[=[
	@within Sencha
	@yields
	@client

	Yields until every replicator the server has defined has its first value on this client, including ones whose
	modules the client hasn't required yet. After it returns, `get()` is safe on every replicator.

	Call it once while loading, before starting systems that read replicated values. If it's still waiting after 5
	seconds it warns and lists what it's waiting on.
]=]
function Sencha.waitForReplicators()
	assert(RunService:IsClient(), "Sencha.waitForReplicators can only be called on the client")
	ReplicationClient.waitForInitialFetch()
end

return table.freeze(Sencha)

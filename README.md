<!-- Links -->

[sencha/releases]: https://github.com/JDevon/sencha/releases/latest
[sencha/wally]: https://wally.run/package/jdevon/sencha

<!-- Badges -->

[badges/github]: https://raw.githubusercontent.com/gist/cxmeel/0dbc95191f239b631c3874f4ccf114e2/raw/github.svg
[badges/wally]: https://raw.githubusercontent.com/gist/cxmeel/0dbc95191f239b631c3874f4ccf114e2/raw/wally.svg

# Sencha

A network package built around [GreenTea](https://github.com/corecii/greentea). Includes strictly typed remotes and replicators.

Full API reference at [jdevon.github.io/sencha](https://jdevon.github.io/sencha/).

## Core features

- **[One shared module](#usage)**: defines a feature's remotes and replicators for both the server and the client.
- **[Typed remotes](#remotes)**: events, unreliable events, functions and switchboards, with arguments and return
  values checked on both sides.
- **[Built-in protection](#rate-limits-and-rejected-calls)**: per-player rate limits and type checks on every call
  from a client, with warnings that can't flood your output.
- **[Server-owned state](#replicators)**: saved and temporary replicators that send server values to one player or
  the whole server.
- **[Saved data without lock-in](#saved-replicators)**: replicate parts of a player's save file from any data store,
  with the save data fully typed.
- **[Incremental updates](#incremental-updates)**: send small patches instead of whole values.
- **[React ready](#react)**: `getObservable` works with the ReactObservableValue hooks.

## Install

[![badges/github]][sencha/releases] [![badges/wally]][sencha/wally]

Install with [Wally](https://wally.run) by adding Sencha and GreenTea to your `wally.toml`:

```toml
[dependencies]
Sencha = "jdevon/sencha@0.1.0"
GreenTea = "corecii/greentea@0.4.11"
```

## Usage

Define a feature's remotes and replicators in one module that the server and the client both require:

```lua
-- ReplicatedStorage/CurrencyNetwork.luau
local Sencha = require(ReplicatedStorage.Packages.Sencha)
local gt = require(ReplicatedStorage.Packages.GreenTea)

return Sencha.define(script, {
	-- remotes
	buyItemRemote = Sencha.func(gt.args(gt.string()), gt.returns(gt.boolean())),

	-- replicators
	coinsReplicator = Sencha.temporaryReplicator.player(gt.number(), 0),
	shopDiscountReplicator = Sencha.temporaryReplicator.global(gt.number(), 0), -- a store-wide sale every player sees
})
```

Every Sencha implementation gets its name from its key in `Sencha.define`, so the same module resolves to the same remotes and
replicators on both sides.

```lua
-- server
CurrencyNetwork.buyItemRemote:onServerInvoke(function(player, itemId)
	return CurrencyNetwork.coinsReplicator:tryUpdate(player, function(coins)
		if coins < 10 then
			return false
		end
		return true, coins - 10
	end)
end)

-- client
Sencha.waitForReplicators() -- once, while loading

print(CurrencyNetwork.coinsReplicator:get())
CurrencyNetwork.coinsReplicator:onChanged(function(_player, newCoins, oldCoins)
	print(`coins went from {oldCoins} to {newCoins}`)
end)
local bought = CurrencyNetwork.buyItemRemote:invokeServer("sword")
```

Use remotes for **requests and one-off events**. Use a replicator for **state the client should always have a current
copy of**.

## Remotes

| Constructor | Use |
|---|---|
| `Sencha.event(...types)` | a `RemoteEvent` with checked arguments |
| `Sencha.unreliableEvent(...types)` | same as above, sent through an `UnreliableRemoteEvent` |
| `Sencha.func(gt.args(...), gt.returns(...))` | a `RemoteFunction` with checked arguments and return values |
| `Sencha.eventSwitchboard(...types)` | one `RemoteEvent` that routes client calls by port name |
| `Sencha.funcSwitchboard(gt.args(...), gt.returns(...))` | one `RemoteFunction` that routes client calls by port name |

Unreliable events may drop messages or deliver them out of order, with payloads limited to roughly 900 bytes.

### Rate limits and rejected calls

The server checks calls from clients in this order: **port** (switchboards), **rate limit**, then **argument types**.
A call that fails any of them is rejected:

- **Events** drop the call.
- **Functions** error back to the waiting client.
- **The server warns once per player, remote and reason**, then stays quiet for that combination for 60 seconds, so a
  flood of bad calls can't bury real errors.

Every remote allows **60 calls at once and 30 per second** per player by default. Change it where the remote is
defined:

```lua
sellItemRemote = Sencha.event(gt.string(), gt.number()):rateLimit({ burst = 10, perSecond = 4 }),
```

Switchboards keep a separate budget for each port, so unrelated actions don't share one.

Calls your own code makes (`fireServer`, `invokeServer`, `fireClient`, and return values) error on bad types, since
those are mistakes in your code.

## Replicators

Three kinds. All are owned by the server: clients can never write to them.

| | Saved | `temporaryReplicator.player` | `temporaryReplicator.global` |
|---|---|---|---|
| Value comes from | part of the player's saved data | server memory, one value per player | server memory, one value |
| Sent to | that player only | that player only | every player |
| Changed by | updating the saved data | `set(player, value)` | `set(value)` |
| Cleared | when the player leaves | when the player leaves | never |

**A player's data is only ever sent to that player.** State other players need to see goes through a global
replicator, so the server always chooses what becomes public.

| Method | Where | What it does |
|---|---|---|
| `get` | both | returns the value without yielding; errors if it isn't available yet |
| `getAsync` | both | yields until the value is available, then returns it |
| `onChanged` | both | fires on changes, not for the first value |
| `set` / `applyIncrementalUpdate` | server, temporary only | changes the value and sends it to clients |
| `tryUpdate` | server, temporary only | calls a function with the current value, and sets what it returns if it returns `true` |
| `observe` | client | fires right away if the value has arrived (otherwise when it arrives), then on every change |
| `getObservable` | client | returns an [ObservableValue](https://github.com/JDevon/observable-value) that follows the value |
| `isLoaded` | client | whether the value has arrived |
| `onUpdateReceived` | client | fires for each patch received (see [Incremental updates](#incremental-updates)) |

On the server, player replicators take the player as their first argument (`get(player)`, `set(player, value)`), and
`onChanged` passes the player first on both sides.

- **Every listener method returns a function that disconnects it.** It's safe to call twice, works as a task for any
  cleanup library, and can be returned straight from a React effect.
- **On the server, a change is sent to clients before `onChanged` fires**, so anything a listener changes in response
  reaches clients after the change that caused it.
- **`set` errors at the caller** if the value doesn't match the replicator's type. Setting a primitive to the value it
  already has does nothing. Tables always count as a change.
- **`tryUpdate` can't yield.** Its function runs without yielding, so nothing else can change the value between
  reading and setting it. A yield errors.
- **Values are frozen** on both sides.

### React

Use `getObservable` with [ReactObservableValue](https://github.com/JDevon/react-observable-value):

```lua
local function CoinsLabel()
	local coins = ReactObservableValue.useObservableValue(CurrencyNetwork.coinsReplicator:getObservable())
	return React.createElement("TextLabel", { Text = `{coins} coins` })
end
```

### Saved replicators

A saved replicator is a read-only view of part of a player's saved data. To change it, update the saved data, and the
change replicates. This keeps one way to write, so an update to several fields at once stays atomic.

Saved replicators come from a **saved source**, one per store of saved player data (your DataStore wrapper of choice, a web
service, etc.). Create each source in a shared module with a unique name and the store's built GreenTea type:

```lua
-- ReplicatedStorage/PlayerDataSource.luau
return Sencha.savedSource("PlayerData", PlayerDataTypes.PlayerData)

-- in a network module
researchReplicator = PlayerDataSource:replicator(gt.array(gt.string()), function(playerData)
	return playerData.research
end),
```

The saved data passed to the lookup is fully typed from the source's GreenTea type, so a misspelled field is a type
error.

On the server, connect each source to its store. Sencha doesn't depend on any specific data store library:

```lua
-- a fetch function that yields until the player's data has loaded, or returns nil if it never loads
PlayerDataSource:setFetchFunction(function(player)
	local didLoad, playerData = PlayerDataServer.waitForPlayerData(player)
	return if didLoad then playerData else nil
end)

-- in the store's change callback, including the first load (oldData is nil)
PlayerDataSource:replicateChanges(player, newData, oldData)
```

Changes are found by comparing what each lookup returns, so **a lookup must return an existing table from the saved
data, or a primitive**. A lookup that builds a new table counts as changed on every save. Data stores that keep
unchanged tables as the same table (like [Lyra](https://github.com/paradoxum-games/lyra)) only send what changed.
Be wary of data stores that deep copy the whole save on every change: every table becomes new, so every replicator
that returns a table resends its full value and fires `onChanged` on every save, even when its part didn't change.

### Incremental updates

By default every change sends the whole value. For large values that change a little at a time, a replicator can send
**patches** instead, by passing an incremental config as its last argument:

```lua
-- temporary: send patches with applyIncrementalUpdate
exportLogReplicator = Sencha.temporaryReplicator.player(ExportTypes.ExportLog, {}, {
	patchType = ExportTypes.ExportLog, -- the entries just exported
	apply = function(log, newEntries)
		local newLog = table.clone(log)
		table.move(newEntries, 1, #newEntries, #newLog + 1, newLog)
		return newLog
	end,
}),

-- then on the server, only the new entry is sent, not the whole log
ExportNetwork.exportLogReplicator:applyIncrementalUpdate(player, { exportedEntry })

-- saved: the server works out each patch itself with diff
backpackReplicator = PlayerDataSource:replicator(InventoryTypes.Items, function(playerData)
	return playerData.backpack
end, {
	patchType = InventoryTypes.ItemsDiff,
	diff = InventoryUtil.diffItems, -- (newValue, oldValue) -> patch
	apply = InventoryUtil.applyItemsDiff, -- (value, patch) -> newValue
}),
```

- **`apply` runs on the server and the client**, so both always hold the same value. It must return a new table and
  never edit its input, since values are frozen.
- For saved replicators, `apply(old, diff(new, old))` must equal `new`.
- Players who join, and replicators defined later, always get a full value first.
- After the first value, an incremental replicator only sends patches, unless a temporary replicator's `set` sends a
  whole value.
- A patch failing on the client means a bug, like an `apply` that gives different results on each side. It errors in
  Studio and warns in live games, and the client ignores that replicator's patches until the server sends a whole
  value. The server also checks that each saved replicator's `apply` matches its `diff`: in Studio a mismatch errors,
  and in live games it warns once per replicator.
- `onUpdateReceived` only fires for patches. Use `onChanged` to see every change.

## Patterns

Player replicators hold a separate value for each player, so they can send different data to different players. These
patterns build on that, with no extra features needed.

### Sending to a group of players

To send the same value to a group, like a party, set it for each member. Every member's value can be the same frozen
table, so this costs no extra memory:

```lua
-- shared
partyReplicator = Sencha.temporaryReplicator.player(PartyTypes.PartyState, PartyTypes.NO_PARTY),

-- server
local function syncParty(party)
	for _, member in party.members do
		PartyNetwork.partyReplicator:set(member, party.state)
	end
end

local function onJoin(party, player)
	table.insert(party.members, player)
	syncParty(party)
end

local function onLeave(party, player)
	table.remove(party.members, table.find(party.members, player))
	PartyNetwork.partyReplicator:set(player, PartyTypes.NO_PARTY)
	syncParty(party)
end
```

Groups can be created and removed at any time. Keep every change to a group going through one function like
`syncParty`, so no member is missed.

For large group values, send only what changed: give the replicator an incremental config, send each new member the
full value once with `set`, then send every change to all members with `applyIncrementalUpdate`. See
[Interest management](#interest-management) for an example of patches sent to individual players.

### Interest management

To send each player only part of a large table, like the mobs near them, give each player their own view of the table
and update it with patches. The game keeps the full table and decides what each player can see:

```lua
-- shared
MobTypes.MobState = gt.build(gt.table({ kind = gt.string(), health = gt.number() }))
MobTypes.MobMap = gt.build(gt.dictionary(gt.string(), MobTypes.MobState:type()))
-- a mob's new state, or false to remove it
MobTypes.MobPatch = gt.build(gt.dictionary(gt.string(), gt.union(MobTypes.MobState:type(), gt.literal(false))))

function MobTypes.applyPatch(mobs, patch)
	local newMobs = table.clone(mobs)
	for mobId, mobState in patch do
		newMobs[mobId] = if mobState == false then nil else mobState
	end
	return newMobs
end

visibleMobsReplicator = Sencha.temporaryReplicator.player(MobTypes.MobMap, {}, {
	patchType = MobTypes.MobPatch,
	apply = MobTypes.applyPatch,
}),
```

Each player's value in the replicator is exactly the set of mobs they can see, so the server reads it with `get(player)`
instead of keeping its own record:

```lua
-- server
local mobs: { [string]: { state: MobState, model: Model } } = {} -- the full table, kept by the game

-- run for each player periodically: adds mobs that came into range and removes ones that left
local function updateVisibility(player: Player)
	local visible = MobNetwork.visibleMobsReplicator:get(player)
	local patch = {}
	for mobId, mob in mobs do
		local inRange = isInRange(player, mob)
		if inRange and not visible[mobId] then
			patch[mobId] = mob.state
		elseif not inRange and visible[mobId] then
			patch[mobId] = false
		end
	end
	MobNetwork.visibleMobsReplicator:applyIncrementalUpdate(player, patch) -- an empty patch does nothing
end

-- sends a change only to the players who can see that mob
local function sendToViewers(mobId: string, value: MobState | false)
	for _, player in Players:GetPlayers() do
		if MobNetwork.visibleMobsReplicator:get(player)[mobId] then
			MobNetwork.visibleMobsReplicator:applyIncrementalUpdate(player, { [mobId] = value })
		end
	end
end
```

The client renders the first value once, then handles each patch as it arrives. Every change after the first value is a
patch that says exactly what changed:

```lua
-- client
local visibleMobsReplicator = MobNetwork.visibleMobsReplicator

for mobId, mobState in visibleMobsReplicator:get() do
	MobVisuals.spawn(mobId, mobState)
end

visibleMobsReplicator:onUpdateReceived(function(_mobs, oldMobs, patch)
	for mobId, mobState in patch do
		if mobState == false then
			MobVisuals.remove(mobId)
		elseif oldMobs[mobId] then
			MobVisuals.update(mobId, mobState)
		else
			MobVisuals.spawn(mobId, mobState)
		end
	end
end)
```

- **Avoid `set` on this replicator.** `set` sends a whole value, which `onUpdateReceived` doesn't see, so the client's
  visuals would fall out of step with its value. Send every change, including clearing a player's view, as a patch.

## Rules

1. **The server must require every module that defines replicators.** A replicator only exists once its module has
   been required on the server.
2. **Call `Sencha.waitForReplicators()` on the client before starting systems that read replicated values**, or use
   `getAsync` / `observe` in code that may run earlier.
3. **`get` doesn't yield, `getAsync` does.**
4. **Remotes can't send every table.** Use string keys for dictionaries, and avoid arrays with gaps, mixed array and
   string keys, and non-string keys. The server warns when a replicator's type can't be sent intact. In Studio it also checks each value it sends, since some problems (such as an array with gaps) only show up in replicated values.
5. **Avoid putting Instances in replicated values.** With StreamingEnabled, an Instance the client hasn't streamed in arrives
   as `nil`. Send an [InstanceHandle](https://create.roblox.com/docs/reference/engine/datatypes/InstanceHandle)
   instead. The server warns about replicator types that contain Instances.
6. **Don't yield in a saved replicator's [lookup](https://jdevon.github.io/sencha/api/SavedSource#replicator), or in an
   incremental config's `apply` or `diff`** ([saved](https://jdevon.github.io/sencha/api/Sencha#SavedIncrementalConfig),
   [temporary](https://jdevon.github.io/sencha/api/Sencha#TemporaryIncrementalConfig)). A yield errors with a traceback
   to the line that waited.

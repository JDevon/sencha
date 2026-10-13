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
	meteorShowerReplicator = Sencha.temporaryReplicator.global(gt.boolean(), false),
})
```

Every Sencha implementation gets its name from its key in `Sencha.define`, so the same module resolves to the same remotes and
replicators on both sides.

```lua
-- server
CurrencyNetwork.buyItemRemote:onServerInvoke(function(player, itemId)
	return CurrencyNetwork.coinsReplicator:update(player, function(coins)
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
| `update` | server, temporary only | calls a function with the current value, and sets what it returns if it returns `true` |
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
- **`update` can't yield.** Its function runs without yielding, so nothing else can change the value between
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
- If a patch fails on the client, it asks the server for the full value again and ignores patches until it arrives.

## Rules

1. **The server must require every module that defines replicators.** A replicator only exists once its module has
   been required on the server.
2. **Call `Sencha.waitForReplicators()` on the client before starting systems that read replicated values**, or use
   `getAsync` / `observe` in code that may run earlier.
3. **`get` doesn't yield, `getAsync` does.**
4. **Remotes can't send every table.** Use string keys for dictionaries, and avoid arrays with gaps, mixed array and
   string keys, and non-string keys. The server warns about types that can't be sent intact, and in Studio about values.
5. **Lookups, `apply` and `diff` must not yield.** A yield errors with a traceback to the line that waited.

## How it works

All replicators share three remotes created under the Sencha module. When a client starts, it fetches a snapshot of
every replicator's value once. The server takes the snapshot without yielding and marks the player ready in the same
step, so no change can be missed. Changes after that are streamed to ready players with a short id instead of the
replicator's name. Messages that arrive before the snapshot is applied are held and applied after it.

Values for replicators whose modules the client hasn't required yet are kept until the module is required.

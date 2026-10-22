local gt = require(script.Parent.Parent.Parent.GreenTea)

export type IncrementalConfig<T, P> = {
	patchType: P,
	apply: (value: T, patch: P) -> T,
}
export type TemporaryIncrementalConfig<T, P> = IncrementalConfig<T, P>
export type SavedIncrementalConfig<T, P> = {
	patchType: P,
	diff: (newValue: T, oldValue: T) -> P,
	apply: (value: T, patch: P) -> T,
}

local ReplicationShared = {}

-- values are wrapped so nil values survive being placed in the snapshot table
local payloadKinds = gt.build(gt.union(gt.literal("value"), gt.literal("patch")))
export type PayloadKinds = typeof(payloadKinds:type())

local valuePayload = gt.build(gt.table({ kind = gt.literal("value"), value = gt.optional(gt.any()) }))
local patchPayload = gt.build(gt.table({ kind = gt.literal("patch"), patch = gt.any() }))
export type ValuePayload = typeof(valuePayload:type())
export type PatchPayload = typeof(patchPayload:type())

-- one replicator's update
local replicatorPayload = gt.build(gt.union(valuePayload:type(), patchPayload:type()))
export type ReplicatorPayload = typeof(replicatorPayload:type())

-- a replicator update held back while a player's predicted request runs, then sent inside a batch
local heldMessage = gt.build(gt.table({
	id = gt.number({ integer = true }),
	payload = replicatorPayload:type(),
	key = gt.optional(gt.string()),
}))
export type HeldMessage = typeof(heldMessage:type())

-- a predicted request's held updates, sent together with its ack or cancel on channel id 0
local batchPayload = gt.build(gt.table({
	kind = gt.literal("batch"),
	messages = gt.array(heldMessage:type()),
	ack = gt.optional(gt.number({ integer = true })),
	cancel = gt.optional(gt.number({ integer = true })),
}))
export type BatchPayload = typeof(batchPayload:type())

ReplicationShared.snapshotEntry =
	gt.build(gt.table({ id = gt.number({ integer = true }), payload = valuePayload:type() }))
export type SnapshotEntry = typeof(ReplicationShared.snapshotEntry:type())
export type Snapshot = { [string]: SnapshotEntry }

-- anything the ReplicationStream remote carries: a replicator update, or a batch of them
ReplicationShared.streamPayload = gt.build(gt.union(valuePayload:type(), patchPayload:type(), batchPayload:type()))
export type StreamPayload = typeof(ReplicationShared.streamPayload:type())

return ReplicationShared

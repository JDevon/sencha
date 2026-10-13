local gt = require(script.Parent.Parent.Parent.GreenTea)
local RemoteEvent = require(script.Parent.Parent.Remotes.Kinds.RemoteEvent)
local RemoteFunction = require(script.Parent.Parent.Remotes.Kinds.RemoteFunction)

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
ReplicationShared.SENCHA_MODULE = script.Parent.Parent
ReplicationShared.FETCH_REMOTE_NAME = "ReplicationFetch"
ReplicationShared.STREAM_REMOTE_NAME = "ReplicationStream"
ReplicationShared.RESYNC_REMOTE_NAME = "ReplicationResync"

-- values are wrapped so nil values survive being placed in the snapshot table
local payloadKinds = gt.build(gt.union(gt.literal("value"), gt.literal("patch")))
export type PayloadKinds = typeof(payloadKinds:type())

local valuePayload = gt.build(gt.table({ kind = gt.literal("value"), value = gt.optional(gt.any()) }))
local patchPayload = gt.build(gt.table({ kind = gt.literal("patch"), patch = gt.any() }))
export type ValuePayload = typeof(valuePayload:type())
export type PatchPayload = typeof(patchPayload:type())

local snapshotEntry = gt.build(gt.table({ id = gt.number({ integer = true }), payload = valuePayload:type() }))
export type SnapshotEntry = typeof(snapshotEntry:type())
export type Snapshot = { [string]: SnapshotEntry }

local payload = gt.build(gt.union(valuePayload:type(), patchPayload:type()))
export type Payload = typeof(payload:type())

ReplicationShared.fetchRemote = RemoteFunction.new(
	gt.args(),
	gt.returns(gt.boolean(), gt.optional(gt.dictionary(gt.string(), snapshotEntry:type())))
):rateLimit({ burst = 5, perSecond = 2 })
ReplicationShared.streamRemote =
	RemoteEvent.new(gt.number({ integer = true }), payload:type(), gt.optional(gt.string()))
ReplicationShared.resyncRemote = RemoteEvent.new(gt.string()):rateLimit({ burst = 5, perSecond = 1 })

return ReplicationShared

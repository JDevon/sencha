local ReplicationShared = require(script.Parent)
local gt = require(script.Parent.Parent.Parent.Parent.GreenTea)
local RemoteEvent = require(script.Parent.Parent.Parent.Remotes.Kinds.RemoteEvent)
local RemoteFunction = require(script.Parent.Parent.Parent.Remotes.Kinds.RemoteFunction)

local ReplicationRemotes = {}
ReplicationRemotes.SENCHA_MODULE = script.Parent.Parent.Parent
ReplicationRemotes.FETCH_REMOTE_NAME = "ReplicationFetch"
ReplicationRemotes.STREAM_REMOTE_NAME = "ReplicationStream"

ReplicationRemotes.fetchRemote = RemoteFunction.new(
	gt.args(),
	gt.returns(gt.boolean(), gt.optional(gt.dictionary(gt.string(), ReplicationShared.snapshotEntry:type())))
):rateLimit({ burst = 5, perSecond = 2 })
ReplicationRemotes.streamRemote =
	RemoteEvent.new(gt.number({ integer = true }), ReplicationShared.streamPayload:type(), gt.optional(gt.string()))

return ReplicationRemotes

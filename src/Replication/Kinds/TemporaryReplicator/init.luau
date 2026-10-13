local TemporaryPlayerReplicator = require(script.TemporaryPlayerReplicator)
local TemporaryGlobalReplicator = require(script.TemporaryGlobalReplicator)

return table.freeze({
	player = TemporaryPlayerReplicator.new,
	global = TemporaryGlobalReplicator.new,
})

local RunService = game:GetService("RunService")

local ChannelRegistry = require(script.Parent.ChannelRegistry)
local ReplicationClient = require(script.Parent.Parent.ReplicationClient)
local ReplicationServer = require(script.Parent.Parent.ReplicationServer)

return function(channel: ChannelRegistry.Channel, name: string, parent: Instance)
	local key = `{parent:GetFullName()}.{name}`
	if RunService:IsServer() then
		ReplicationServer.openChannel(channel, key)
	else
		ReplicationClient.openChannel(channel, key)
	end
end

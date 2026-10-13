local ReplicatorChannel = require(script.ReplicatorChannel)

export type Channel = ReplicatorChannel.ReplicatorChannel<any, any>

local channels: { [string]: Channel } = {}

local ChannelRegistry = {}

function ChannelRegistry.addChannel(channel: Channel)
	if channels[channel.key] then
		error(`Replicator {channel.key} is already registered`)
	end
	channels[channel.key] = channel
end

function ChannelRegistry.getChannel(key: string): Channel?
	return channels[key]
end

function ChannelRegistry.getChannels(): { [string]: Channel }
	return channels
end

return ChannelRegistry

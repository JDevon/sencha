local isBatching = false
local deferredChannels: { [any]: true } = {}

local ChannelBatch = {}

function ChannelBatch.begin()
	isBatching = true
end

function ChannelBatch.isBatching(): boolean
	return isBatching
end

function ChannelBatch.defer(channel: any)
	deferredChannels[channel] = true
end

function ChannelBatch.finish(): { any }
	isBatching = false
	local channels = {}
	for channel in deferredChannels do
		table.insert(channels, channel)
	end
	table.clear(deferredChannels)
	return channels
end

return ChannelBatch

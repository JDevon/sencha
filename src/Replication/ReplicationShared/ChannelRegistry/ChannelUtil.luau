local ReplicationShared = require(script.Parent.Parent)

local noYielding = require(script.Parent.Parent.Parent.Parent.Util.noYielding)

export type ChannelRead<T> = (player: Player, context: any) -> T

local ChannelUtil = {}

function ChannelUtil.guardIncrementalConfig<T, P>(
	incrementalConfig: ReplicationShared.IncrementalConfig<T, P>?
): ReplicationShared.IncrementalConfig<T, P>?
	if not incrementalConfig then
		return nil
	end

	local noYieldConfig = table.clone(incrementalConfig) :: any
	noYieldConfig.apply = function(value, patch)
		return noYielding(function()
			return incrementalConfig.apply(value, patch)
		end)
	end

	local diff = (incrementalConfig :: ReplicationShared.SavedIncrementalConfig<T, P>).diff
	if diff then
		noYieldConfig.diff = function(newValue, oldValue)
			return noYielding(function()
				return diff(newValue, oldValue)
			end)
		end
	end

	return noYieldConfig
end

function ChannelUtil.guardConfiguredRead<T>(read: ChannelRead<T>): ChannelRead<T>
	return function(player: Player, context: any): T
		return noYielding(read, player, context)
	end
end

-- a frozen deep copy, so later edits to the caller's table can't change the stored value
function ChannelUtil.copyAndFreeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = ChannelUtil.copyAndFreeze(child)
	end
	return table.freeze(copy) :: any
end

function ChannelUtil.freezeInPlace(value: any)
	if type(value) ~= "table" or table.isfrozen(value) then
		return
	end
	for _, child in value do
		ChannelUtil.freezeInPlace(child)
	end
	table.freeze(value)
end

return ChannelUtil

local RemoteTypechecker = {}
RemoteTypechecker.__index = RemoteTypechecker

export type RemoteTypechecker<T...> = typeof(setmetatable(
	{} :: {
		checker: (T...) -> (),
	},
	{} :: {
		__index: {
			check: (RemoteTypechecker<T...>, ...any) -> T...,
			matches: (RemoteTypechecker<T...>, ...any) -> (boolean, any),
		},
	}
))

function RemoteTypechecker.new<T...>(checker: any): RemoteTypechecker<T...>
	local self = setmetatable({}, RemoteTypechecker)
	self.checker = checker
	return self :: any
end

function RemoteTypechecker.check<T...>(self: RemoteTypechecker<T...>, ...: any): T...
	return (self.checker :: any):assert(...)
end

function RemoteTypechecker.matches<T...>(self: RemoteTypechecker<T...>, ...: any): (boolean, any)
	return (self.checker :: any):matches(...)
end

return table.freeze({
	new = RemoteTypechecker.new,
	fromArgs = function<T...>(checker: (T...) -> ()): RemoteTypechecker<T...>
		return RemoteTypechecker.new(checker)
	end,
	fromReturns = function<T...>(checker: () -> T...): RemoteTypechecker<T...>
		return RemoteTypechecker.new(checker)
	end,
})

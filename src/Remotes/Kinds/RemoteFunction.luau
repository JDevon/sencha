local RunService = game:GetService("RunService")

local Cleanup = require(script.Parent.Parent.Parent.Cleanup)
local RateLimiter = require(script.Parent.Parent.RateLimiter)
local RemoteLoader = require(script.Parent.Parent.RemoteLoader)
local DefineHooks = require(script.Parent.Parent.Parent.DefineHooks)
local RemoteRejections = require(script.Parent.Parent.RemoteRejections)
local RemoteTypechecker = require(script.Parent.Parent.RemoteTypechecker)

--[=[
	@class Function

	A typed `RemoteFunction` the client invokes on the server, created with [Sencha.func]. Arguments and return
	values are checked against its GreenTea types.

	A call from a client that is rate limited or has invalid arguments errors back to the waiting client with a
	short message that never repeats what it sent, and the server warns once per player, remote and reason.
]=]
local RemoteFunction = {}
RemoteFunction.__index = RemoteFunction

export type Function<T..., R...> = typeof(setmetatable(
	{} :: {
		cleanup: Cleanup.Cleanup,
		loader: RemoteLoader.RemoteLoader<RemoteFunction>,
		argTypechecker: RemoteTypechecker.RemoteTypechecker<T...>,
		retTypechecker: RemoteTypechecker.RemoteTypechecker<R...>,
		rateLimiter: RateLimiter.RateLimiter?,
		rejections: RemoteRejections.RemoteRejections?,
	},
	{} :: {
		__index: {
			invokeServer: (Function<T..., R...>, T...) -> R...,
			onServerInvoke: (Function<T..., R...>, (Player, T...) -> R...) -> (),
			rateLimit: (Function<T..., R...>, RateLimiter.Limit) -> Function<T..., R...>,
			destroy: (Function<T..., R...>) -> (),
		},
	}
))

function RemoteFunction.new<T..., R...>(args: (T...) -> (), ret: () -> R...): Function<T..., R...>
	local self = setmetatable({}, RemoteFunction)
	self.cleanup = Cleanup.new()

	local remoteFunctionInstance: RemoteFunction?
	if RunService:IsServer() then
		local instance = Instance.new("RemoteFunction")
		remoteFunctionInstance = instance
		self.cleanup:add(instance)

		self.rateLimiter = RateLimiter.new()
		self.cleanup:add(function()
			self.rateLimiter:destroy()
		end)

		self.rejections = RemoteRejections.new()
		self.cleanup:add(function()
			self.rejections:destroy()
		end)
	end

	self.loader = RemoteLoader.new(remoteFunctionInstance)
	self.argTypechecker = RemoteTypechecker.fromArgs(args)
	self.retTypechecker = RemoteTypechecker.fromReturns(ret)

	DefineHooks.set(self, function(name, parent)
		self.loader:load(name, parent)

		if self.rejections then
			self.rejections:setName(`{parent:GetFullName()}.{name}`)
		end
	end)

	return self :: any
end

--[=[
	@method invokeServer
	@within Function
	@client
	@yields

	Calls the server's callback and returns what it returns.

	@param ... T...
	@return R...
]=]
function RemoteFunction.invokeServer<T..., R...>(self: Function<T..., R...>, ...: T...): R...
	assert(RunService:IsClient(), "RemoteFunction.invokeServer can only be called from the client")
	return self.retTypechecker:check(self.loader:assertInstance():InvokeServer(self.argTypechecker:check(...)))
end

--[=[
	@method onServerInvoke
	@within Function
	@server

	Sets the callback that answers calls from clients. Setting it again replaces the previous callback.

	@param callback (player: Player, T...) -> R...
]=]
function RemoteFunction.onServerInvoke<T..., R...>(self: Function<T..., R...>, callback: (Player, T...) -> R...)
	assert(RunService:IsServer(), "RemoteFunction.onServerInvoke can only be called from the server")
	local rateLimiter = assert(self.rateLimiter, "RateLimiter should exist on the server.")
	local rejections = assert(self.rejections, "RemoteRejections should exist on the server.")
	self.loader:assertInstance().OnServerInvoke = function(player, ...)
		if not rateLimiter:tryConsume(player) then
			rejections:reject(player, "rate limited")
			error(`{rejections:getName()} is rate limited; try again shortly`, 0)
		end

		local ok, cause = self.argTypechecker:matches(...)
		if not ok then
			rejections:reject(player, "invalid arguments", nil, cause:formatErr())
			error(`{rejections:getName()} received invalid arguments`, 0)
		end

		return self.retTypechecker:check(callback(player, ...))
	end
end

--[=[
	@method rateLimit
	@within Function
	@server

	Sets the rate limit for calls from each player, replacing the default of 60 at once and 30 per second. Returns
	the same function, so it can be chained where it's created. Errors if the limit is invalid.

	```lua
	buyItemRemote = Sencha.func(gt.args(gt.string()), gt.returns(gt.boolean())):rateLimit({ burst = 5, perSecond = 2 }),
	```

	@param limit Limit
	@return Function
]=]
function RemoteFunction.rateLimit<T..., R...>(self: Function<T..., R...>, limit: RateLimiter.Limit): Function<T..., R...>
	RateLimiter.validateLimit(limit)
	if RunService:IsServer() then
		assert(self.rateLimiter, "RateLimiter should exist on the server."):setLimit(limit)
	end
	return self
end

--[=[
	@method destroy
	@within Function

	Destroys the remote instance on the server.
]=]
function RemoteFunction.destroy<T..., R...>(self: Function<T..., R...>)
	self.cleanup:destroy()
end

return table.freeze({
	new = RemoteFunction.new,
})

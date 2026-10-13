local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Cleanup = require(script.Parent.Parent.Util.Cleanup)

type PlayerBucket = { tokens: number, last: number }
export type Limit = { burst: number, perSecond: number }

local DEFAULT_LIMITS = { burst = 60, perSecond = 30 }
local DEFAULT_BUCKET = "default"

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		cleanup: Cleanup.Cleanup,
		limits: Limit,
		buckets: { [Player]: { [string]: PlayerBucket } },
		clock: () -> number,
	},
	RateLimiter
))

function RateLimiter.validateLimit(limit: Limit)
	if limit.burst < 1 then
		error("RateLimiter.validateLimit: burst must be greater than or equal to 1", 3)
	end
	if limit.perSecond <= 0 then
		error("RateLimiter.validateLimit: perSecond must be greater than 0", 3)
	end
end

function RateLimiter.new(clock: (() -> number)?): RateLimiter
	local self = setmetatable({}, RateLimiter)
	self.cleanup = Cleanup.new()
	self.limits = DEFAULT_LIMITS
	self.buckets = {}
	self.clock = clock or os.clock

	if RunService:IsServer() then
		self.cleanup:add(Players.PlayerRemoving:Connect(function(player)
			self.buckets[player] = nil
		end))
	end

	return self
end

function RateLimiter.tryConsume(self: RateLimiter, player: Player, bucketKey: string?): boolean
	local key = if bucketKey == nil then DEFAULT_BUCKET else bucketKey

	local now = self.clock()
	local playerBuckets = self.buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		self.buckets[player] = playerBuckets
	end

	local bucket = playerBuckets[key]
	if not bucket then
		local newBucket = { tokens = self.limits.burst, last = now }
		playerBuckets[key] = newBucket
		bucket = newBucket
	end

	bucket.tokens = math.min(self.limits.burst, bucket.tokens + (now - bucket.last) * self.limits.perSecond)
	bucket.last = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1

	return true
end

function RateLimiter.setLimit(self: RateLimiter, limit: Limit)
	RateLimiter.validateLimit(limit)
	self.limits = limit

	for _, playerBuckets in self.buckets do
		for _, bucket in playerBuckets do
			bucket.tokens = limit.burst
			bucket.last = self.clock()
		end
	end
end

function RateLimiter.destroy(self: RateLimiter)
	self.cleanup:destroy()
end

return table.freeze({
	new = RateLimiter.new,
	validateLimit = RateLimiter.validateLimit,
})

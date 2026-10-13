local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Cleanup = require(script.Parent.Parent.Cleanup)

export type Reason = "rate limited" | "invalid arguments" | "unknown port"

local REJECTION_WARN_INTERVAL_SECONDS = 60
local MAX_DETAIL_LENGTH = 300

local RemoteRejections = {}
RemoteRejections.__index = RemoteRejections

export type RemoteRejections = typeof(setmetatable(
	{} :: {
		cleanup: Cleanup.Cleanup,
		remoteName: string?,
		warned: { [Player]: { [string]: true } },
	},
	RemoteRejections
))

function RemoteRejections.new(): RemoteRejections
	local self = setmetatable({}, RemoteRejections)
	self.cleanup = Cleanup.new()
	self.warned = {}

	if RunService:IsServer() then
		self.cleanup:add(Players.PlayerRemoving:Connect(function(player)
			self.warned[player] = nil
		end))
	end

	return self
end

function RemoteRejections.setName(self: RemoteRejections, name: string)
	self.remoteName = name
end

function RemoteRejections.getName(self: RemoteRejections): string
	return self.remoteName or "(undefined remote)"
end

function RemoteRejections.reject(self: RemoteRejections, player: Player, reason: Reason, port: string?, detail: string?)
	local playerWarned = self.warned[player]
	if not playerWarned then
		playerWarned = {}
		self.warned[player] = playerWarned
	end

	local warnKey = if port then `{reason}:{port}` else reason
	if playerWarned[warnKey] then
		return
	end
	playerWarned[warnKey] = true

	local portText = if port then ` port "{port}"` else ""
	local detailText = if detail then `\n{string.sub(detail, 1, MAX_DETAIL_LENGTH)}` else ""
	warn(
		`Rejected a call to {self:getName()}{portText} from {player.Name}: {reason}.`
			.. ` Further rejections of this type for player {player.Name} will be dropped silently for {REJECTION_WARN_INTERVAL_SECONDS}s.`
			.. detailText
	)

	task.delay(REJECTION_WARN_INTERVAL_SECONDS, function()
		local stillWarned = self.warned[player]
		if not stillWarned then
			return
		end

		stillWarned[warnKey] = nil
		if not next(stillWarned) then
			self.warned[player] = nil
		end
	end)
end

function RemoteRejections.destroy(self: RemoteRejections)
	self.cleanup:destroy()
end

return table.freeze({
	new = RemoteRejections.new,
})

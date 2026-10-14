local RemoteSerialization = {}

local INSTANCE_ISSUE = "is an Instance, which arrives as nil on clients that haven't streamed it in. "
	.. "InstanceHandles are recommended for this use case: https://create.roblox.com/docs/reference/engine/datatypes/InstanceHandle"

local function childPath(path: string, key: any): string
	if type(key) == "string" then
		return `{path}.{key}`
	end
	return `{path}[{tostring(key)}]`
end

local function findIssueAt(value: any, path: string, ancestors: { [any]: true }): string?
	local valueType = typeof(value)
	if valueType == "function" or valueType == "thread" then
		return `{path} is a {valueType}, which remotes cannot send`
	elseif valueType == "Instance" then
		return `{path} {INSTANCE_ISSUE}`
	end

	if valueType ~= "table" then
		return nil
	end

	if ancestors[value] then
		return `{path} refers back to one of its own parent tables, which remotes cannot send`
	end

	if getmetatable(value) ~= nil then
		return `{path} has a metatable, which is lost when sent`
	end

	local hasStringKeys = false
	local numberKeyCount = 0
	local largestNumberKey = 0
	for key in value do
		local keyType = typeof(key)
		if keyType == "string" then
			hasStringKeys = true
		elseif keyType == "number" then
			if key % 1 ~= 0 or key < 1 then
				return `{path} has the number key {key}; only array indices 1, 2, 3... survive being sent`
			end
			numberKeyCount += 1
			largestNumberKey = math.max(largestNumberKey, key)
		else
			return `{path} has a {keyType} key, which is converted to a string when sent`
		end
	end

	if hasStringKeys and numberKeyCount > 0 then
		return `{path} mixes array indices and string keys, so only part of it survives being sent`
	end

	if numberKeyCount ~= largestNumberKey then
		return `{path} is an array with gaps, so values after the first gap may be lost when sent`
	end

	ancestors[value] = true
	for key, child in value do
		local issue = findIssueAt(child, childPath(path, key), ancestors)
		if issue then
			return issue
		end
	end
	ancestors[value] = nil

	return nil
end

-- returns a description of the first part of the value that would not survive a remote, or nil
function RemoteSerialization.findIssue(value: any): string?
	return findIssueAt(value, "value", {})
end

-- what a table key type allows: "string", "number", "mixed" (both), "unknown" (any / unknown, can't tell), or "other"
local function keyKind(keyType: any): string
	local kind = keyType.kind
	if kind == "string" or kind == "number" then
		return kind
	elseif kind == "any" or kind == "unknown" then
		return "unknown"
	elseif kind == "literal" then
		local literalType = typeof(keyType.literal.value)
		return if literalType == "string" or literalType == "number" then literalType else "other"
	elseif kind == "basic" then
		local basicType = keyType.basic.typeof or keyType.basic.type
		return if basicType == "string" or basicType == "number" then basicType else "other"
	elseif kind == "union" then
		local combined: string? = nil
		for _, option in keyType.union.contents do
			local optionKind = keyKind(option)
			if optionKind == "unknown" or optionKind == "other" then
				return optionKind
			elseif combined and combined ~= optionKind then
				return "mixed"
			end
			combined = optionKind
		end
		return combined or "other"
	end
	return "other"
end

local function findTypeIssueAt(gtType: any, path: string, visited: { [any]: true }): string?
	if visited[gtType] then
		return nil
	end
	visited[gtType] = true

	local kind = gtType.kind
	if kind == "function" then
		return `{path} is a function, which remotes cannot send`
	elseif kind == "thread" then
		return `{path} is a thread, which remotes cannot send`
	elseif kind == "InstanceIsA" or (kind == "basic" and gtType.basic.typeof == "Instance") then
		return `{path} {INSTANCE_ISSUE}`
	elseif kind == "union" or kind == "intersection" then
		for _, option in gtType[kind].contents do
			local issue = findTypeIssueAt(option, path, visited)
			if issue then
				return issue
			end
		end
	elseif kind == "custom" and gtType.custom.type then
		return findTypeIssueAt(gtType.custom.type, path, visited)
	elseif kind == "table" then
		local tableInfo = gtType.table
		local indexer = tableInfo.indexer
		local hasFields = next(tableInfo.contents) ~= nil

		if indexer then
			local indexerKeyKind = keyKind(indexer.key)
			if indexerKeyKind == "other" then
				return `{path} is keyed by something other than strings or numbers, which remotes convert to strings`
			elseif indexerKeyKind == "mixed" then
				return `{path} mixes string and number keys, so only part of it survives being sent`
			elseif indexerKeyKind == "number" and hasFields then
				return `{path} mixes array indices with named fields, so only part of it survives being sent`
			end

			local keyLabel = if indexerKeyKind == "unknown" then "any" else indexerKeyKind
			local issue = findTypeIssueAt(indexer.value, `{path}[{keyLabel}]`, visited)
			if issue then
				return issue
			end
		end

		for field, fieldType in tableInfo.contents do
			local issue = findTypeIssueAt(fieldType, `{path}.{field}`, visited)
			if issue then
				return issue
			end
		end
	end

	return nil
end

-- returns a description of the first part of a GreenTea type that describes something a remote can't send intact,
-- or nil. Values can still break in ways a type can't express (an array with gaps), which findIssue catches
function RemoteSerialization.findTypeIssue(gtType: any, label: string): string?
	return findTypeIssueAt(gtType, label, {})
end

return RemoteSerialization

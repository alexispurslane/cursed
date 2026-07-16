--- Lane module registry.
---
--- Each lane-facing client module registers itself here via
--- `require("cursed.lane_registry").register(LANE_IDX, M)`,
--- typically at the bottom of the module file. This lets main.lua
--- iterate over all registered modules to call setup/reinitialize
--- uniformly instead of hardcoding each module's lifecycle calls.
---
--- Registered module interface (all optional):
---   setup(ss, editor, es)       — initialize the module
---   reinitialize(ss, editor, es) — post-lane-crash recovery
---   flush_pending()              — emit synthetic errors for in-flight ops
---   pending_count()              — integer for headless drain loop

local M = {}
local _lanes = {}  -- [lane_idx] = module_table
local _by_lane = {} -- sorted list for deterministic iteration

function M.register(lane_idx, mod)
	_lanes[lane_idx] = mod
	table.insert(_by_lane, { lane_idx = lane_idx, mod = mod })
	table.sort(_by_lane, function(a, b)
		return a.lane_idx < b.lane_idx
	end)
end

function M.get(lane_idx)
	return _lanes[lane_idx]
end

--- Iterate registered modules in lane_idx order.
--- Returns an iterator suitable for `for lane_idx, mod in reg.each() do`.
function M.each()
	local i = 0
	return function()
		i = i + 1
		local entry = _by_lane[i]
		if entry then
			return entry.lane_idx, entry.mod
		end
	end
end

--- Call setup(ss, es) on every registered module.
function M.setup_all(ss, es)
	for _, mod in pairs(_lanes) do
		if mod.setup then
			mod.setup(ss, es)
		end
	end
end

--- Call flush_pending() for a specific lane.
function M.flush_pending(lane_idx)
	local mod = _lanes[lane_idx]
	if mod and mod.flush_pending then
		mod.flush_pending()
	end
end

--- Call reinitialize(ss, editor, es) for a specific lane.
function M.reinitialize(lane_idx, ss, editor, es)
	local mod = _lanes[lane_idx]
	if mod and mod.reinitialize then
		mod.reinitialize(ss, editor, es)
	end
end

--- Sum all registered pending_count() values.
function M.total_pending()
	local count = 0
	for _, mod in pairs(_lanes) do
		if mod.pending_count then
			count = count + mod.pending_count()
		end
	end
	return count
end

return M

--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Represents a Mission within the game and this associates an
-- Objective to as assigned group of units responsible for
-- completing the Objective.
--]]

-- TODO:
--  * have a joinable flag in the mission class only let
--    assets join when the flag is true

require("os")
require("math")
local utils    = require("libs.utils")
local class    = require("libs.namedclass")
local enum     = require("dct.enum")
local dctutils = require("dct.utils")
local uicmds   = require("dct.ui.cmds")
local State    = require("dct.libs.State")
local Timer    = require("dct.libs.Timer")

local MISSION_LIMIT = 60*60*3  -- 3 hours in seconds
local PREP_LIMIT    = 60*90    -- 90 minutes in seconds


---------------- STATES ------------

local BaseMissionState = class("BaseMissionState", State)
function BaseMissionState:timeremain()
	return 0
end

function BaseMissionState:timeextend(--[[addtime]])
end

local TimeoutState = class("TimeoutState", BaseMissionState)
function TimeoutState:enter(msn)
	msn:queueabort(enum.missionAbortType.TIMEOUT)
end

local SuccessState = class("SuccessState", BaseMissionState)
function SuccessState:enter(msn)
	-- TODO: we could convert to emitting a DCT event to handle rewarding
	-- tickets, this would require a little more than just emitting an
	-- event here. Would require changing Tickets class a little too.
	dct.Theater.singleton():getTickets():reward(msn.cmdr.owner,
		msn.reward, true)
	msn:queueabort(enum.missionAbortType.COMPLETE)
end

--[[
-- ActiveState - mission is active and executing the plan
--  Critera:
--    * on plan completion, mission success
--    * on timer expired, mission timed out
--]]
local ActiveState  = class("ActiveState",  BaseMissionState)
function ActiveState:__init()
	self.timer = Timer(MISSION_LIMIT)
	self.action = nil
end

function ActiveState:enter(msn)
	self.timer:reset()
	self.action = msn.plan.pophead()
end

function ActiveState:update(msn)
	self.timer:update()
	if self.timer:expired() then
		return TimeoutState()
	end

	if self.action == nil then
		return SuccessState()
	end
	self.action:update(msn)
	if self.action:complete(msn) then
		local newaction = msn.plan:pophead()
		self.action:exit(msn)
		self.action = newaction
		self.action:enter(msn)
	end
	return nil
end

function ActiveState:timeremain()
	return self.timer:remain()
end

function ActiveState:timeextend(addtime)
	self.timer:extend(addtime)
end

--[[
-- PrepState - mission is being planned
--  Maintains a timer and once the timer expires the mission expires.
--]]
-- TODO: find some way to remove players from mission if they de-slot
-- and mission in prep state
local PrepState = class("PrepState", State)
function PrepState:__init()
	self.timer = Timer(PREP_LIMIT)
end

function PrepState:enter()
	self.timer:reset()
end

function PrepState:update(msn)
	self.timer:update()
	if self.timer:expired() then
		return TimeoutState()
	end

	for _, v in pairs(msn:getAssigned()) do
		local asset =
			dct.Theater.singleton():getAssetMgr():getAsset(v)
		if asset.type == enum.assetType.PLAYERGROUP and
		   asset:inAir() then
			return ActiveState()
		end
	end
	return nil
end

function PrepState:timeremain()
	return self.timer:remain()
end

function PrepState:timeextend(addtime)
	self.timer:extend(addtime)
end

local function composeBriefing(msn, tgt)
	local briefing = tgt.briefing
	local interptbl = {
		["TOT"] = os.date("!%F %Rz",
			dctutils.zulutime(msn:getTimeout()*.6)),
	}
	return dctutils.interp(briefing, interptbl)
end

local Mission = class("Mission")
function Mission:__init(cmdr, missiontype, tgtname, plan)
	self.cmdr      = cmdr
	self.type      = missiontype
	self.target    = tgtname
	self.plan      = plan
	self.iffcodes  = cmdr:genMissionCodes(missiontype)
	self.id        = self.iffcodes.id
	self.assigned  = {}
	self:_setComplete(false)
	self.state     = PrepState()
	self.state:enter(self)

	-- compose the briefing at mission creation to represent
	-- known intel the pilots were given before departing
	local tgt = dct.Theater.singleton():getAssetMgr():getAsset(tgtname)
	self.briefing  = composeBriefing(self, tgt)
	tgt:setTargeted(self.cmdr.owner, true)
end

function Mission:getID()
	return self.id
end

function Mission:isMember(name)
	local i = utils.getkey(self.assigned, name)
	if i then
		return true, i
	end
	return false
end

function Mission:getAssigned()
	return utils.shallowclone(self.assigned)
end

function Mission:addAssigned(asset)
	if self:isMember(asset.name) then
		return
	end
	table.insert(self.assigned, asset.name)
	asset.missionid = self:getID()
end

function Mission:removeAssigned(asset)
	local member, i = self:isMember(asset.name)
	if not member then
		return
	end
	table.remove(self.assigned, i)
	asset.missionid = 0
end

--[[
-- Abort - aborts a mission for etiher a single group or
--   completely terminating the mission for everyone assigned.
--
-- Things that need to be managed;
--  * remove requesting group from the assigned list
--  * if assigned list is empty or we need to force terminate the
--    mission
--    - remove the mission from the owning commander's mission list(s)
--    - release the targeted asset by resetting the asset's targeted
--      bit
--]]
function Mission:abort(asset)
	self:removeAssigned(asset)
	if next(self.assigned) == nil then
		self.cmdr:removeMission(self.id)
		local tgt = self.cmdr:getAsset(self.target)
		if tgt then
			tgt:setTargeted(self.cmdr.owner, false)
		end
	end
	return self.id
end

function Mission:queueabort(reason)
	self:_setComplete(true)
	local theater = dct.Theater.singleton()
	for _, name in ipairs(self.assigned) do
		local request = {
			["type"]   = enum.uiRequestType.MISSIONABORT,
			["name"]   = name,
			["value"]  = reason,
		}
		-- We have to use theater:queueCommand() to bypass the
		-- limiting of players sending too many commands
		theater:queueCommand(10, uicmds[request.type](theater, request))
	end
end

function Mission:update()
	local newstate = self.state:update(self)
	if newstate ~= nil then
		self.state:exit(self)
		self.state = newstate
		self.state:enter(self)
	end
end

function Mission:_setComplete(val)
	self._complete = val
end

function Mission:isComplete()
	return self._complete
end

--[[
-- getTargetInfo - provide target information
--
-- The target information supplied:
--   * location - centroid of the asset
--   * callsign - a short name the target area can be referenced by
--   * description - short two/three word description of the asset
--       like; factory, ammo bunker, etc.
--   * status - numercal value from 0 to 100 representing percentage
--       completion
--   * intellvl - numercal value representing the amount of 'intel'
--       gathered on the asset, dictates targeting coordinates
--       precision too
--]]
function Mission:getTargetInfo()
	local asset = dct.Theater.singleton():getAssetMgr():getAsset(self.target)
	if asset == nil then
		return nil
	end
	local tgtinfo = {}
	tgtinfo.location = asset:getLocation()
	tgtinfo.callsign = asset.codename
	tgtinfo.status   = asset:getStatus()
	tgtinfo.intellvl = asset:getIntel(self.cmdr.owner)
	return tgtinfo
end

function Mission:getTimeout()
	local remain, ctime = self.state:timeremain()
	return ctime + remain
end

function Mission:addTime(time)
	self.state:timeextend(time)
	return time
end

function Mission:getDescription(fmt)
	local tgt = self.cmdr:getAsset(self.target)
	if tgt == nil then
		return "Target destroyed abort mission"
	end
	local interptbl = {
		["LOCATION"] = dctutils.fmtposition(
			tgt:getLocation(),
			tgt:getIntel(self.cmdr.owner),
			fmt)
	}
	return dctutils.interp(self.briefing, interptbl)
end

return Mission

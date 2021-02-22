--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Represents an airspace.
-- Airspaces cannot die (i.e. be deleted), track zero-sum influence of
-- which side "controls" the space, and spawn nothing
--]]

local vector = require("dct.libs.vector")
local AssetBase = require("dct.assets.AssetBase")

local Airspace = require("libs.namedclass")("Airspace", AssetBase)
function Airspace:__init(template, region)
	AssetBase.__init(self, template, region)
	self:_addMarshalNames({
		"_location",
		"_radius",
	})
end

function Airspace:_completeinit(template, region)
	AssetBase._completeinit(self, template, region)
	assert(template.location ~= nil,
		"runtime error: Airspace requires template to define a location")
	self._location = vector.Vector2D(template.location):raw()
	assert(template.radius ~= nil,
		"runtime error: Airspace requires template to define a radius")
	self._radius = template.radius
end

-- TODO: need to figure out how to track influence within this space

return Airspace

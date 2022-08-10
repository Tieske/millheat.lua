--- Compatibility module for Copas and LuaLogging.
-- To use LuaLogging or the Copas scheduler, ensure to load those libs before
-- loading the `millheat` module.
-- @usage
-- local copas = require "copas"
-- local ll = require "logging"
-- local mh = require "millheat"


local compat = {}


-- returns a LuaLogging compatible logger object if LuaLogging was already loaded
-- otherwise returns a stub
local ll = package.loaded.logging
if ll and type(ll) == "table" and ll.defaultLogger and
  tostring(ll._VERSION):find("LuaLogging") then
  -- default LuaLogging logger is available
  compat.log = ll.defaultLogger()
else
  -- just use a stub logger with only no-op functions
  local nop = function() end
  compat.log = setmetatable({}, {
    __index = function(self, key) self[key] = nop return nop end
  })
end


-- returns https request function for Copas if available, otherwise luasec one
local copas = package.loaded.copas
if copas then
  compat.https = require "copas.http"
else
  compat.https = require "ssl.https"
end

return compat

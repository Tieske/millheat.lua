-- set up logging to be used by the module
local ansicolors = require("ansicolors")  -- https://github.com/kikito/ansicolors.lua
local ll = require("logging")             -- https://github.com/lunarmodules/lualogging
require "logging.console"

-- configure the default logger
ll.defaultLogger(ll.console {
  logLevel = ll.INFO, -- DEBUG,           -- try and set to debug to see more details
  destination = "stderr",
  timestampPattern = "%y-%m-%d %H:%M:%S.%q",
  logPatterns = {
    [ll.DEBUG] = ansicolors("%date%{cyan} %level %message %{reset}(%source)\n"),
    [ll.INFO] = ansicolors("%date %level %message\n"),
    [ll.WARN] = ansicolors("%date%{yellow} %level %message\n"),
    [ll.ERROR] = ansicolors("%date%{red bright} %level %message %{reset}(%source)\n"),
    [ll.FATAL] = ansicolors("%date%{magenta bright} %level %message %{reset}(%source)\n"),
  }
})


-- Load Copas first, then the millheat module. This ensure we can use async Copas requests
local copas = require "copas"


-- Load the millheat module
local millheat = require("millheat")

-- Create a Millheat session
local mh = millheat.new {
  username = "someone@here.com",
  password = "sooper secret",
  -- api_key = "xyz some key",
}


local task = function()
  -- fetch the houses for this account, the JSON payload is returned as a Lua table
  local _, houses = assert(mh:srequest("GET:/houses"))

  -- select only our own houses from the response
  local houses = houses.ownHouses or {}

  -- loop over the houses
  for _, house in ipairs(houses) do
    -- get the independent devices for this house
    local _, devices = assert(mh:srequest("GET:/houses/{houseId}/devices/independent", {
      houseId = house.id
    }))

    -- select the devices in the 'items' array of the response
    devices = devices.items or {}
    mh.log:info("House: '%s' (id: %s), has %d independent devices", house.name, house.id, #devices)

    -- loop over the devices
    for _, device in ipairs(devices) do

      -- get the device details
      local deviceName = device.customName or "unnamed device"
      local ambient = (device.lastMetrics or {}).temperatureAmbient
      local setpoint = (device.lastMetrics or {}).temperature
      local unit = ((device.deviceSettings or {}).reported or {}).display_unit or "(unknown unit)"

      mh.log:info("Device: '%s', current temperature: %d, setpoint: %d (%s)", deviceName, ambient, setpoint, unit)

      -- increase setpoint by 1 degree
      assert(mh:srequest("PATCH:/devices/{deviceId}/settings", {
        deviceId = device.deviceId
      }, {
        deviceType = device.deviceType.parentType.name,
        enabled = device.isEnabled,
        settings = {
          operation_mode = "independent_device",   -- manual controllable, with timers
          temperature_normal = setpoint + 1,       -- increase setpoint by one.
        }
      }))

      mh.log:info("Setpoint for '%s' increased to %d", deviceName, setpoint + 1)
    end
  end

  mh:logout()
end


-- start the async scheduler and run the task
copas(task)

print("Copas exited")

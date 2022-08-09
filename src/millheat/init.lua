--- Millheat API library for Millheat electrical heaters.
--
-- This library implements the session management and makes it easy to access
-- individual endpoints of the API.
--
-- @author Thijs Schreijer
-- @license millheat.lua is free software under the MIT/X11 license.
-- @copyright 2020-2022 Thijs Schreijer
-- @release Version x.x, Library to acces the Millheat API
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local home_list, err = mhsession:get_homes()

local url = require "socket.url"
local ltn12 = require "ltn12"
local json = require "cjson.safe"
local socket = require "socket"

local millheat = {}
local millheat_mt = { __index = millheat }




local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' -- You will need this for encoding/decoding
local function base64_decode(data)
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
            return string.char(c)
    end))
end


-------------------------------------------------------------------------------
-- Generic functions.
-- Functions for session management and instantiation
-- @section Generic


local BASE_URL="https://api.millheat.com:443"
local CLOCK_SKEW = 5 * 60 -- clock skew in seconds to allow when refreshing tokens
-- https method is set on the module table, such that it can be overridden
-- by another implementation (eg. Copas)
millheat.https = require "ssl.https"
-- Logger is set on the module table, to be able to override it
-- supports: debug, info, warn, error, fatal
-- log:debug([message]|[table]|[format, ...]|[function, ...])
millheat.log = require("logging.console")()





-- Performs a HTTP request on the Millheat API.
-- @param path (string) the relative path within the API base path
-- @param method (string) HTTP method to use
-- @param headers (table) optional header table
-- @param query (table) optional query parameters (will be escaped)
-- @param body (table/string) optional body. If set the "Content-Length" will be
-- added to the headers. If a table, it will be send as JSON, and the
-- "Content-Type" header will be set to "application/json".
-- @return ok, response_body, response_code, response_headers, response_status_line
local function mill_request(path, method, headers, query, body)
  local response_body = {}
  headers = headers or {}

  query = query or {} do
    local r = {}
    local i = 0
    for k, v in pairs(query) do
      r[i] = "&"
      r[i+1] = url.escape(k)
      r[i+2] = "="
      r[i+3] = url.escape(v)
      i = i + 4
    end
    query = "?" .. table.concat(r)
    if query == "?" then
      query = ""
    end
  end

  if type(body) == "table" then
    body = json.encode(body)
    headers["Content-Type"] =  "application/json"
  end
  headers["Content-Length"] = #(body or "")

  local r = {
    method = assert(method, "2nd parameter 'method' missing"):upper(),
    url = BASE_URL .. assert(path, "1st parameter 'relative-path' missing") .. query,
    headers = headers,
    source = ltn12.source.string(body or ""),
    sink = ltn12.sink.table(response_body),
  }
  millheat.log:debug("[millheat] making api request to: %s %s", r.method, r.url)
  --millheat.log:debug(r)  -- not logging because of credentials

  local ok, response_code, response_headers, response_status_line = millheat.https.request(r)
  if not ok then
    millheat.log:error("[millheat] api request failed with: %s", response_code)
    return ok, response_code, response_headers, response_status_line
  end

  if type(response_body) == "table" then
    response_body = table.concat(response_body)
  end

  for name, value in pairs(response_headers) do
    if name:lower() == "content-type" and value:find("application/json", 1, true) then
      -- json body, decode
      response_body = assert(json.decode(response_body))
      break
    end
  end
--print("Response: "..require("pl.pretty").write({
--  body = response_body,
--  status = response_code,
--  headers = response_headers,
--}))
  millheat.log:debug("[millheat] api request returned: %s", response_code)

  return ok, response_body, response_code, response_headers, response_status_line
end



-- parse a token and return its expiry time.
-- This takes into account the clock-skew setting
local function get_token_expiry(token)
  assert(type(token) == "string", "expected a 'string', got: " .. type(token))

  local payload = token:match("%.(.*)%.")
  if not payload then
    return nil, "bad JWT token"
  end

  local data, err = json.decode(base64_decode(payload))
  if not data then
    return nil, err
  end

  local expiry = data.exp
  if not expiry then return
    nil, "no 'exp' claim found in token"
  end
  return expiry - CLOCK_SKEW
end



-- sets the tokens in the session object.
-- while doing so it will parse the tokens and extract the expiry time
local function set_tokens(self, access, refresh)
  self.access_token = access
  if access ~= nil then
    millheat.log:debug("[millheat] storing access_token for %s", self.username)
    self.access_token_expires = assert(get_token_expiry(access))
  else
    millheat.log:debug("[millheat] clearing access_token for %s", self.username)
    self.access_token_expires = nil
  end

  self.refresh_token = refresh
  if refresh ~= nil then
    millheat.log:debug("[millheat] storing refresh_token for %s", self.username)
    self.refresh_token_expires = assert(get_token_expiry(refresh))
  else
    millheat.log:debug("[millheat] clearing refresh_token for %s", self.username)
    self.refresh_token_expires = nil
  end
  return true
end



-- Gets the refresh token, if not set or expired, it will be automatically
-- renewed.
local function get_refresh_token(self)
  if self.refresh_token and self.refresh_token_expires > socket.gettime() then
    -- refresh token still valid
    return self.refresh_token
  end

  -- login and get tokens
  millheat.log:debug("[millheat] refresh_token expired/unavailable, getting authorization_code for %s", self.username)
  local ok, response_body = self:rewrite_error(200,
    mill_request("/share/applyAuthCode", "POST", {
        access_key = self.access_key,
        secret_token = self.secret_token,
      })
  )
  if not ok then
    millheat.log:error("[millheat] failed to get authorization_code: %s", response_body)
    return nil, "failed to get authorization_code: "..response_body
  end
  local authorization_code = assert((response_body.data or {}).authorization_code, "response is missing authorization_code")

  local query = {
    username = self.username,
    password = self.password,
  }
  local headers = {
    authorization_code = authorization_code,
  }

  millheat.log:debug("[millheat] getting refresh_token for %s", self.username)
  ok, response_body = self:rewrite_error(200, mill_request("/share/applyAccessToken", "POST", headers, query))
  if not ok then
    millheat.log:error("[millheat] failed to get access and refresh tokens: %s", response_body)
    return nil, "failed to get access and refresh tokens: "..response_body
  end

  set_tokens(self, response_body.data.access_token, response_body.data.refresh_token)
  return self.refresh_token
end



-- gets the access token, if not set or expired, it will be automatically
-- fetched/refreshed.
local function get_access_token(self)
  local now = socket.gettime()
  local access = self.access_token

  if access and self.access_token_expires > now then
    -- access token still valid
    return access
  end

  -- no access token, or expired
  millheat.log:debug("[millheat] access_token expired/unavailable for %s", self.username)
  local refresh, err = get_refresh_token(self)
  if not refresh then
    return nil, err
  end

  if self.access_token == access then
    -- the access token wasn't updated while fetching the refresh token
    -- essentially: access was expired, refresh still valid, so we need to
    -- make a refresh call
    millheat.log:debug("[millheat] getting access_token for %s", self.username)
    local ok, response_body = self:rewrite_error(200,
      mill_request("/share/refreshtoken", "POST", nil, {
        refreshtoken = refresh,
      })
    )
    if not ok then
      millheat.log:error("[millheat] failed to refresh the access token: %s", response_body)
      return nil, "failed to refresh the access token: "..response_body
    end

    set_tokens(self, response_body.data.access_token, response_body.data.refresh_token)
  end

  return self.access_token
end



--- Creates a new Millheat session instance.
-- @tparam string access_key the `access_key` to use for login
-- @tparam string secret_token the `secret_token` to use for login
-- @tparam string username the `username` to use for login
-- @tparam string password the `password` to use for login
-- @return Millheat session object
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- end
function millheat.new(access_key, secret_token, username, password)
  local self = {
    access_key = assert(access_key, "1st parameter, 'access_key' is missing"),
    secret_token = assert(secret_token, "2nd parameter, 'secret_token' is missing"),
    username = assert(username, "3rd parameter, 'username' is missing"),
    password = assert(password, "4th parameter, 'password' is missing"),
  }
  millheat.log:debug("[millheat] created new instance for %s", self.username)
  return setmetatable(self, millheat_mt)
end



--- Performs a HTTP request on the Millheat API.
-- It will automatically inject authentication/session data. Or if not logged
-- logged in yet, it will log in. If the session has expired it will be renewed.
--
-- NOTE: if the response_body is json, then it will be decoded and returned as
-- a Lua table.
-- @tparam string path the relative path within the API base path
-- @tparam[opt] table query query parameters (will be escaped)
-- @return `ok`, `response_body`, `response_code`, `response_headers`, `response_status_line`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
--
-- local query = { ["param1"] = "value1" }
--
-- -- the following line will automatically log in
-- local ok, response_body, status, headers, statusline = mhsession:request("/some/path", query)
function millheat:request(path, query)
  local access_token, err = get_access_token(self) -- this will auto-login
  if not access_token then
    return access_token, err
  end
  return mill_request(path, "POST", { access_token = access_token }, query, nil)
end


--- Rewrite errors to Lua format (nil+error).
-- Takes the output of the `request` function and validates it for errors;
--
-- - nil+err
-- - body with "success = false" (some API calls return a 200 with success=false for example)
-- - mismatch in expected status code (a 200 expected, but a 404 received)
--
-- This reduces the error handling to standard Lua errors, instead of having to
-- validate each of the situations above individually.
-- @tparam[opt] number expected expected status code, if `nil`, it will be ignored
-- @param ... same parameters as the `request` method
-- @return `nil+err` or the input arguments
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("myself@nothere.com", "secret_password")
--
-- -- Make a request where we expect a 200 result
-- local ok, response_body, status, headers, statusline = mhsession:rewrite_error(200, mhsession:request("/some/path"))
-- if not ok then
--   return nil, response_body -- a 404 will also follow this path now, since we only want 200's
-- end
function millheat:rewrite_error(expected, ok, body, status, headers, ...)
  if not ok then
    return ok, body
  end

  if type(body) == "table" and body.success == false then
    return nil, tostring(status)..": "..json.encode(body)
  end

  if expected ~= nil and expected ~= status then
    if type(body) == "table" then
      body = json.encode({body = body, headers = headers})
    end
    return nil, "bad return code, expected " .. expected .. ", got "..status..". Response: "..body
  end

  return ok, body, status, headers, ...
end



--- Logs out of the current session.
-- There is no real logout option with this API. Hence this only deletes
-- the locally stored tokens.
-- @return `true`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- else
--   mhsession:logout()
-- end
function millheat:logout()
  millheat.log:debug("[millheat] logout for %s", self.username)
  set_tokens(self, nil, nil)
end



--- Logs in the current session.
-- This will automatically be called by the `request` method, if not logged in
-- already.
-- @return `true` or `nil+err`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- end
function millheat:login()
  millheat.log:debug("[millheat] logging in for %s", self.username)
  local access, err = get_access_token(self)  -- will force a login if required
  return access and true, err
end



-------------------------------------------------------------------------------
-- API specific functions.
-- This section contains functions that directly interact with the Millheat API.
-- @section API



--- Gets the list of homes.
-- @return list, or nil+err
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local home_list = mhsession:get_homes()
function millheat:get_homes()

  local ok, response_body = self:rewrite_error(200, self:request("/uds/selectHomeList"))
  if not ok then
    millheat.log:error("[millheat] failed to get home list: %s", response_body)
    return nil, "failed to get home list: "..response_body
  end

  return response_body.data.homeList
end


--- Gets the list of rooms associated with a home.
-- @tparam string|number home_id the home for which to get the list of rooms
-- @return list, or nil+err
function millheat:get_rooms_by_home(home_id)
  if type(home_id) ~= "string" then
    if type(home_id) ~= "number" then
      error("expected home_id to be a string or number")
    end
    home_id = string.format("%d", home_id)
  end

  local ok, response_body = self:rewrite_error(200, self:request("/uds/selectRoombyHome2020", { homeId = home_id }))
  if not ok then
    millheat.log:error("[millheat] failed to get room list: %s", response_body)
    return nil, "failed to get room list: "..response_body
  end

  return response_body.data.roomList
end


--- Gets the list of devices associated with a room.
-- @tparam string|number room_id the room for which to get the list of devices
-- @return list, or nil+err
function millheat:get_devices_by_room(room_id)
  if type(room_id) ~= "string" then
    if type(room_id) ~= "number" then
      error("expected room_id to be a string or number")
    end
    room_id = string.format("%d", room_id)
  end

  local ok, response_body = self:rewrite_error(200, self:request("/uds/selectDevicebyRoom2020", { roomId = room_id }))
  if not ok then
    millheat.log:error("[millheat] failed to get device list: %s", response_body)
    return nil, "failed to get device list: "..response_body
  end

  return response_body.data.deviceList
end


--- Gets the list of independent devices not associated with a room.
-- @tparam string|number home_id the home for which to get the list of independent devices
-- @return list, or nil+err
function millheat:get_independent_devices_by_home(home_id)
  if type(home_id) ~= "string" then
    if type(home_id) ~= "number" then
      error("expected home_id to be a string or number")
    end
    home_id = string.format("%d", home_id)
  end

  local ok, response_body = self:rewrite_error(200, self:request("/uds/getIndependentDevices2020", { homeId = home_id }))
  if not ok then
    millheat.log:error("[millheat] failed to get independent devices list: %s", response_body)
    return nil, "failed to get independent devices list: "..response_body
  end

  return response_body.data.deviceInfoList
end


--- Gets the device data.
-- @tparam string|number device_id the device for which to get the data
-- @return list, or nil+err
function millheat:get_device(device_id)
  if type(device_id) ~= "string" then
    if type(device_id) ~= "number" then
      error("expected home_id to be a string or number")
    end
    device_id = string.format("%d", device_id)
  end

  local ok, response_body = self:rewrite_error(200, self:request("/uds/selectDevice2020", { deviceId = device_id }))
  if not ok then
    millheat.log:error("[millheat] failed to get device data: %s", response_body)
    return nil, "failed to get device data: "..response_body
  end

  return response_body.data.deviceInfo
end


--- Controls a specific device.
-- @tparam string|number device_id the device to control
-- @tparam "temperature"|"switch" operation the operation to perform
-- @tparam "room"|"single"|"on"|"off"|true|false status either "room" or single" (for a `temperature` operation), or "on"/true or "off"/false (for a `switch` operation).
-- @tparam[opt] number temperature the temperature (integer) to set, only has an effect with "temperature"+"single" operation and status.
-- @return true or nil+err
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new("abcdef", "xyz", "myself@nothere.com", "secret_password")
-- local ok, err = mhsession:control_device(123, "temperature", "single", 19)
-- if not ok then
--   print("failed to control the device: ", err)
-- end
function millheat:control_device(device_id, operation, status, temperature)

  if type(device_id) ~= "string" then
    if type(device_id) ~= "number" then
      error("expected device_id to be a string or number")
    end
    device_id = string.format("%d", device_id)
  end

  status = tostring(status):lower()
  operation = tostring(operation):lower()
  if operation == "temperature" then
    operation = "1"

    if status == "single" then
      status = "1"
    elseif status == "room" then
      status = "0"
    else
      error("with operation 'temperature', status must be either 'single' or 'room', got: " .. status)
    end

  elseif operation == "switch" then
    operation = "0"

    if status == "on" or status == "true" then
      status = "1"
    elseif status == "off" or status == "false" then
      status = "0"
    else
      error("with operation 'switch', status must be either 'on'/true or 'off'/false, got: " .. status)
    end

  else
    error("operation must be either 'temperature' or 'switch', got: " .. operation)
  end

  if operation == "1" and status == "1" then
    if type(temperature) ~= "number" then
      error("temperature must be a number, got: " .. type(temperature))
    end
    temperature = tostring(math.floor(temperature + 0.5))
  end


  local ok, response_body = self:rewrite_error(200, self:request("/uds/deviceControlForOpenApi", {
    deviceId = device_id,
    holdTemp = temperature,
    operation = operation,
    status = status,
  }))
  if not ok then
    millheat.log:error("[millheat] failed to control device: %s", response_body)
    return nil, "failed to control device: "..response_body
  end

  return true
end


return millheat

--- Millheat API library for Millheat electrical heaters.
--
-- This library implements the session management and makes it easy to access
-- individual endpoints of the API.
--
-- API documentation: [http://mn-be-prod-documentation.s3-website.eu-central-1.amazonaws.com/#/](http://mn-be-prod-documentation.s3-website.eu-central-1.amazonaws.com/#/).
--
-- @author Thijs Schreijer
-- @license millheat.lua is free software under the MIT/X11 license.
-- @copyright 2020-2024 Thijs Schreijer
-- @release Version 0.4.0, Library to access the Millheat API
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   -- use username/password OR apikey, not both!
--   username = "name@email.org",
--   password = "secret_password",
--   -- api_key = "xyz",
-- }
--
-- local ok, data = self:srequest("GET:/houses/{houseId}/rooms", { houseId = "some-id-here" })
-- if not ok then
--   print("failed to get rooms: ", data)
-- end
--
-- mhsession:logout()
--
-- @usage
-- -- or using the Copas scheduler
-- local copas = require "copas"
--
-- copas.addthread(function()
--   local millheat = require "millheat"
--   local mhsession = millheat.new {
--     -- use username/password OR apikey, not both!
--     username = "name@email.org",
--     password = "secret_password",
--     -- api_key = "xyz",
--   }
--
--   local ok, data = self:srequest("GET:/houses/{houseId}/rooms", { houseId = "some-id-here" })
--   if not ok then
--     print("failed to get rooms: ", data)
--   end
--
--   mhsession:logout()
-- end)
--
-- copas.loop()

local url = require "socket.url"
local ltn12 = require "ltn12"
local json = require "cjson.safe"
local socket = require "socket"

--- The module table containing some global settings and constants.
-- @table millheat
--
-- @field https
-- This is a function set on the module table, such that it can
-- be overridden by another implementation. If [Copas](https://lunarmodules.github.io/copas/)) was
-- loaded before this module then `copas.http` will be used, otherwise it
-- uses the [LuaSec](https://github.com/lunarmodules/luasec) one (module `ssl.https`).
--
-- @field log
-- Logger is set on the module table, to be able to override it.
-- Default is the [LuaLogging](https://lunarmodules.github.io/lualogging/) default logger if LuaLogging
-- was loaded before this module. Otherwise it uses a stub logger with only no-op functions.
local millheat = {}
local millheat_mt = { __index = millheat }

local session_cache = setmetatable({}, { __mode = "v" })


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


local BASE_URL="https://api.millnorwaycloud.com:443"
local CLOCK_SKEW = 1 * 60 -- clock skew in seconds to allow when refreshing tokens

do
  local compat = require "millheat.compat"
  -- https method is set on the module table, such that it can be overridden
  -- by another implementation (eg. Copas)
  millheat.https = compat.https
  -- Logger is set on the module table, to be able to override it
  -- supports: debug, info, warn, error, fatal
  -- log:debug([message]|[table]|[format, ...]|[function, ...])
  millheat.log = compat.log
end




local function get_session_cache_key(self)
  local sep = "|"
  return tostring(self.api_key) .. sep .. tostring(self.username) .. sep .. tostring(self.password)
end

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
-- print("Response: "..require("pl.pretty").write({
--   body = response_body,
--   status = response_code,
--   headers = response_headers,
-- }))
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
  assert(self.api_key == nil, "api_key based sessions do not have refresh tokens")

  if self.refresh_token and self.refresh_token_expires > socket.gettime() then
    -- refresh token still valid
    return self.refresh_token
  end

  -- login and get tokens
  millheat.log:debug("[millheat] refresh_token expired/unavailable, logging in %s", self.username)
  local ok, response_body = self:rewrite_error(200,
    mill_request("/customer/auth/sign-in", "POST", {}, nil, {
        login = self.username,
        password = self.password,
      })
  )
  if not ok then
    millheat.log:error("[millheat] failed to login: %s", response_body)
    return nil, "failed to login: "..response_body
  end

  set_tokens(self, response_body.idToken, response_body.refreshToken)
  return self.refresh_token
end



-- gets the authorization headers, if not set or expired, it will be automatically
-- fetched/refreshed. If auth by API key then those headers will be returned.
local function get_authorization_headers(self)
  if self.api_key then
    -- use api key, so look no further...
    return { ["X-Api-Key"] = self.api_key }
  end

  local now = socket.gettime()
  local access = self.access_token

  if access and self.access_token_expires > now then
    -- access token still valid
    return {
      Authorization = "Bearer " .. access,
    }
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
      mill_request("/customer/auth/refresh", "POST", nil, {
        Authorization = "Bearer " .. refresh,
      })
    )
    if not ok then
      millheat.log:error("[millheat] failed to refresh the access token: %s", response_body)
      return nil, "failed to refresh the access token: "..response_body
    end

    set_tokens(self, response_body.idToken, response_body.refreshToken)
  end

  return {
    Authorization = "Bearer " .. self.access_token,
  }
end



--- Creates a new Millheat session instance.
-- If a session for the credentials already exists, the existing session is
-- returned. See `millheat.logout` for destroying sessions.
--
-- Use either `username+password` OR `api_key`, not both.
-- @tparam table opts the options table, supporting the following options:
-- @tparam[opt] string opts.username the `username` to use for login
-- @tparam[opt] string opts.password the `password` to use for login
-- @tparam[opt] string opts.api_key the `api_key` to use for login
-- @return Millheat session object
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- end
function millheat.new(opts)
  assert(type(opts) == "table", "expected an options table, got: " .. type(opts))
  if type(opts.api_key) == "string" then
    assert(opts.username == nil and opts.password == nil, "when 'api_key' is set, 'username' and 'password' should not be set")
  elseif opts.apikey == nil then
    assert(type(opts.username) == "string", "expected a 'string' for 'username', got: " .. type(opts.username))
    assert(type(opts.password) == "string", "expected a 'string' for 'password', got: " .. type(opts.password))
  else
    error("expected a 'api_key' to be a string or be omitted, got: " .. type(opts.apikey))
  end

  local self = {
    username = opts.username or "[username unknown: api-key used]",
    password = opts.password,
    api_key = opts.api_key,
  }

  local key = get_session_cache_key(self)
  local session = session_cache[key]
  if session then
    -- session already exists
    millheat.log:debug("[millheat] returning existing instance from cache for %s", self.username)
    return session
  end

  setmetatable(self, millheat_mt)
  session_cache[key] = self

  millheat.log:debug("[millheat] created new instance for %s", self.username)
  return self
end



--- Performs a HTTP request on the Millheat API.
-- It will automatically inject authentication/session data. Or if not
-- logged in yet, it will log in. If the session has expired it will be renewed.
--
-- This method is a low-level method, and is used by the higher level `srequest`.
-- The latter is recommended for use in most cases since it is easier to use and
-- more readable.
--
-- NOTE: if the response_body is JSON, then it will be decoded and returned as
-- a Lua table.
-- @tparam string path the relative path within the API base path
-- @tparam[opt="GET"] string method the http method to use (will be capitalized)
-- @tparam[opt] table query query parameters (will be escaped)
-- @tparam[opt] table|string body request body, a table will be encoded as json
-- @return `ok`, `response_body`, `response_code`, `response_headers`, `response_status_line`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
--
-- local body = { param1 = "value1" }
--
-- -- the following line will automatically log in
-- local ok, response_body, status, headers, statusline = mhsession:request("/some/path", "GET", nil, body)
function millheat:request(path, method, query, body)
  local headers, err = get_authorization_headers(self) -- this will auto-login
  if not headers then
    return headers, err
  end

  return mill_request(path, (method or "GET"):upper(), headers, query, body)
end

--- Smart HTTP request on the Millheat API.
-- It will automatically inject authentication/session data, and login if required.
-- Parameters will be injected in the path, remaining ones will be added to the query.
-- Responses in `20x` range will be valid, anything else is returned as a Lua error.
-- @tparam string path the relative path within the API base path, format: `"METHOD:/path/{param1}/to/{param2}"`. Method defaults to "GET".
-- @tparam[opt] table params parameters, path parameters will be injected, others will be added to the query (they will be escaped).
-- @tparam[opt] table|string body request body, a table will be encoded as json
-- @return `ok`, `response_body`, `response_code`, `response_headers`, `response_status_line` or `nil+error`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
--
-- local house_id = "xyz some id"
--
-- -- the following line will automatically log in, and fetch the data
-- local ok, data = mhsession:srequest("GET:/houses/{houseId}/devices", {
--   houseId = house_id,
-- })
-- if not ok then
--   print("failed to get devices: ", data)
-- end
function millheat:srequest(path, params, body)
  local method = path:match("^([a-zA-Z]+):")
  if not method then
    method = "GET"
  else
    path = path:sub(#method + 2, -1)
  end

  if path:sub(1,1) ~= "/" then
    error("path must start with a '/', got: " .. path)
  end

  path = path:gsub("({[^}]+})", function (param)
    local name = param:sub(2, -2)
    local value = params[name]
    if not value then
      error("missing parameter: " .. name)
    else
      value = url.escape(value)
    end
    params[name] = nil
    return value
  end)

  return self:rewrite_error({
    [200] = 200,
    [201] = 201,
    [202] = 202,
    [203] = 203,
    [204] = 204,
  }, self:request(path, method, params, body))
end

--- Rewrite errors to Lua format (nil+error).
-- Takes the output of the `request` function and validates it for errors;
--
-- - nil+err
-- - mismatch in expected status code (a 200 expected, but a 404 received)
--
-- This reduces the error handling to standard Lua errors, instead of having to
-- validate each of the situations above individually.
-- @tparam[opt] number|table expected expected status code, if `nil`, it will be ignored. If a table then the keys must be the allowed status codes.
-- @param ... same parameters as the `request` method
-- @return `nil+err` on error, or the input arguments
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
--
-- -- Make a request where we expect a 200 or 201 result
-- expected = { 200 = true, 201 = true }
-- local ok, response_body, status, headers, statusline = mhsession:rewrite_error(expected, mhsession:request("/some/path"))
-- if not ok then
--   return nil, response_body -- a 404 will also follow this path now, since we only want 200's
-- end
function millheat:rewrite_error(expected, ok, body, status, headers, ...)
  if not ok then
    return ok, body
  end

  if expected ~= nil then
    if type(expected) ~= "table" then
      expected = { [expected] = true }
    end

    if not expected[status] then
      -- bad response code received
      local err
      if type(body) == "table" then
        err = json.encode({body = body, headers = headers})
      else
        err = tostring(body)
      end
      local list = {}
      for key in pairs(expected) do
        list[#list+1] = tostring(key)
      end
      return nil, "bad return code, expected one of: " .. table.concat(list, ",") .. ". Got "..status..": "..err
    end
  end

  return ok, body, status, headers, ...
end



--- Logs out of the current session.
-- This only applies to user/pwd login. Does nothing for API key auth.
-- @tparam bool clear if truthy, the current session is removed from the session
-- cache, and the next call to `millheat.new` will create a new session instead
-- of reusing the cached one.
-- @return `true` or `nil+err`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- else
--   mhsession:logout()
-- end
function millheat:logout(clear)
  millheat.log:debug("[millheat] logout for %s", self.username)
  if self.api_key then
    return true -- nothing to do here
  end

  if not self.refresh_token or self.refresh_token_expires <= socket.gettime() then
    -- refresh token not set yet, or already expired
    return true -- nothing to do here
  end


  local refresh_token = get_refresh_token(self)
  local ok, response_body = self:rewrite_error(200,
    mill_request("/customer/auth/sign-out", "DELETE", {
      Authorization = "Bearer " .. refresh_token,
    })
  )

  local err
  if not ok then
    err = "failed to logout: "..response_body
    millheat.log:error("[millheat] %s", err)
  end

  set_tokens(self, nil, nil)

  if clear then
    millheat.log:debug("[millheat] clearing session from cache for %s", self.username)
    session_cache[get_session_cache_key(self)] = nil
  end

  return true
end



--- Logs in the current session.
-- This will automatically be called by the `request` and `srequest` methods, if
-- not logged in already. Has no effect for API key auth.
-- @return `true` or `nil+err`
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
-- local ok, err = mhsession:login()
-- if not ok then
--   print("failed to login: ", err)
-- end
function millheat:login()
  local access, err = get_authorization_headers(self)  -- will force a login if required
  return access and true, err
end



-------------------------------------------------------------------------------
-- API specific functions.
-- This section contains functions that directly interact with the Millheat API.
-- @section API



--- Gets the list of houses.
-- Invokes the `GET`:`/houses` endpoint.
-- @return list, or nil+err
-- @usage
-- local millheat = require "millheat"
-- local mhsession = millheat.new {
--   username = "name@email.org",
--   password = "secret_password",
-- }
-- local home_list = mhsession:get_houses()
function millheat:get_houses()
  local ok, response_body = self:srequest("GET:/houses")
  if not ok then
    millheat.log:error("[millheat] failed to get home list: %s", response_body)
    return nil, "failed to get home list: "..response_body
  end

  return response_body
end


return millheat

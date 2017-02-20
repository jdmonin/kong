local utils = require "kong.tools.utils"
local responses = require "kong.tools.responses"

local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local math_max = math.max

local RATELIMIT_LIMIT = "X-RateLimit-Limit"
local RATELIMIT_REMAINING = "X-RateLimit-Remaining"

local _M = {}

local function parse_header(header_value, limits)
  local increments = {}
  if header_value then
    if (type(header_value) == "table") then
      -- multiple headers with same name: combine per RFC 2616 section 4.2
      local hval_str = header_value[1]
      local i
      for i = 2,#header_value do
        hval_str = hval_str .. "," .. header_value[i]
      end
      header_value = hval_str
    end
    local parts = utils.split(header_value, ",")
    for _, v in ipairs(parts) do
      local increment_parts = utils.split(v, "=")
      if #increment_parts == 2 then
        local limit_name = utils.strip(increment_parts[1])
        if limits[limit_name] then -- Only if the limit exists
          increments[utils.strip(increment_parts[1])] = tonumber(utils.strip(increment_parts[2]))
        end
      end
    end
  end
  return increments
end

function _M.execute(conf)
  ngx.ctx.increments = {}

  if not next(conf.limits) then
    return
  end

  -- Parse header
  local increments = parse_header(ngx.header[conf.header_name], conf.limits)
  ngx.ctx.increments = increments

  local usage = ngx.ctx.usage -- Load current usage
  if not usage then return end

  local stop
  for limit_name, v in pairs(usage) do
    for period_name, lv in pairs(usage[limit_name]) do
      ngx.header[RATELIMIT_LIMIT.."-"..limit_name.."-"..period_name] = lv.limit
      ngx.header[RATELIMIT_REMAINING.."-"..limit_name.."-"..period_name] = math_max(0, lv.remaining - (increments[limit_name] and increments[limit_name] or 0)) -- increment_value for this current request

      if increments[limit_name] and increments[limit_name] > 0 and lv.remaining <= 0 then
        stop = true -- No more
      end
    end
  end

  -- Remove header
  ngx.header[conf.header_name] = nil

  -- If limit is exceeded, terminate the request
  if stop then
    ngx.ctx.stop_log = true
    return responses.send(429) -- Don't set a body
  end
end

return _M

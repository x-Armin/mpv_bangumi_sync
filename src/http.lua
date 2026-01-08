local mp_utils = require "mp.utils"

local M = {}

-- 使用curl进行HTTP请求
-- @param url string 请求URL
-- @param options table 请求选项 {method, headers, params, data}
-- @return table {status_code, body, headers}
function M.request(url, options)
  options = options or {}
  local method = options.method or "GET"
  local headers = options.headers or {}
  local params = options.params
  local data = options.data

  -- 构建curl命令
  local args = {"curl", "-s", "-S", "-X", method}

  -- 添加headers
  for key, value in pairs(headers) do
    table.insert(args, "-H")
    table.insert(args, string.format("%s: %s", key, value))
  end

  -- 添加参数
  if params then
    local param_str = {}
    for key, value in pairs(params) do
      -- 简单的URL编码
      local encoded_value = tostring(value):gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
      end)
      table.insert(param_str, string.format("%s=%s", key, encoded_value))
    end
    if #param_str > 0 then
      url = url .. "?" .. table.concat(param_str, "&")
    end
  end

  -- 添加数据
  if data then
    table.insert(args, "-H")
    table.insert(args, "Content-Type: application/json")
    table.insert(args, "-d")
    -- 使用utils的format_json
    local utils = require "src.utils"
    local json_data = utils.format_json(data)
    table.insert(args, json_data)
  end

  table.insert(args, url)

  -- 执行curl命令
  local result = mp.command_native({
    name = "subprocess",
    args = args,
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })

  if result.status ~= 0 then
    mp.msg.error("HTTP request failed: " .. (result.stderr or ""))
    return nil
  end

  local body = result.stdout or ""
  local json_body = mp_utils.parse_json(body)
  
  return {
    status_code = 200, -- curl成功返回200，实际需要从响应头获取
    body = json_body or body,
    raw_body = body,
  }
end

-- GET请求
function M.get(url, options)
  options = options or {}
  options.method = "GET"
  return M.request(url, options)
end

-- POST请求
function M.post(url, options)
  options = options or {}
  options.method = "POST"
  return M.request(url, options)
end

-- PUT请求
function M.put(url, options)
  options = options or {}
  options.method = "PUT"
  return M.request(url, options)
end

return M

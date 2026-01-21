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

  -- 让 curl 在输出末尾写入一个可识别的状态码标记，便于解析真实的 HTTP status
  table.insert(args, "-w")
  table.insert(args, "\n__HTTP_STATUS__:%{http_code}")

  table.insert(args, url)

  -- 执行curl命令
  local result = mp.command_native({
    name = "subprocess",
    args = args,
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })

  -- 日志：打印 subprocess 返回的 result（尽量 JSON 序列化，否则输出关键字段）
  do
    local ok, s = pcall(function() return mp_utils.format_json(result) end)
    if ok and s then
      mp.msg.verbose("http.request subprocess result: " .. s)
    else
      mp.msg.verbose(string.format(
        "http.request subprocess result.status=%s stderr=%s stdout_len=%s",
        tostring(result and result.status or "nil"),
        tostring(result and result.stderr or "<empty>"),
        tostring(#(result and result.stdout or ""))
      ))
    end
  end

  if result.status ~= 0 then
    mp.msg.error("HTTP request subprocess failed: " .. (result.stderr or ""))
  end

  local stdout = result.stdout or ""
  -- 解析通过 -w 写入的状态码标记，格式为 "__HTTP_STATUS__:XXX" 位于输出末尾
  local status_code = tonumber(stdout:match("__HTTP_STATUS__:(%d%d%d)%s*$"))
  local body = stdout:gsub("\n__HTTP_STATUS__:%d%d%d%s*$", "")
  local json_body = mp_utils.parse_json(body)

  -- 打印原始 body 与解析后的 json_body 和解析到的 HTTP status
  mp.msg.verbose("http.request raw_body: " .. (body ~= "" and body or "<empty>"))
  if json_body then
    local ok, s = pcall(function() return mp_utils.format_json(json_body) end)
    if ok and s then
      mp.msg.verbose("http.request json_body: " .. s)
    else
      mp.msg.verbose("http.request json_body (tostring): " .. tostring(json_body))
    end
  else
    mp.msg.verbose("http.request json_body: nil")
  end
  mp.msg.verbose("http.request parsed http status: " .. tostring(status_code or "nil"))

  return {
    status_code = status_code or 0,
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

-- PATCH请求
function M.patch(url, options)
  options = options or {}
  options.method = "PATCH"
  return M.request(url, options)
end

return M

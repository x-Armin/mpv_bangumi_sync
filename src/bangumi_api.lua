local http = require "src.http"
local mp_utils = require "mp.utils"
local paths = require "src.paths"
local config = require "src.config"

local M = {}

-- 辅助：安全序列化任意值为 JSON 字符串用于日志
local function dump_for_log(v)
  if not v then return "nil" end
  if type(v) ~= "table" then return tostring(v) end
  local ok, s = pcall(function() return mp_utils.format_json(v) end)
  if ok and s then return s end
  return tostring(v)
end

local DEFAULT_API_URL = "https://api.bgm.tv"
local API_ERROR_MESSAGE = "Bangumi API 请求失败，请检查 Bangumi 状态或 bangumi_api 配置"
local USERNAME_FILE = mp_utils.join_path(paths.DATA_PATH, "username.json")

local function get_api_url()
  return (config.config and config.config.bangumi_api) or DEFAULT_API_URL
end

local function warn_api_error(res)
  if res and res.detached then
    return
  end
  local status_code = res and tonumber(res.status_code or 0) or 0
  if not res or status_code == 0 or status_code >= 500 then
    mp.msg.error(API_ERROR_MESSAGE .. ": " .. tostring(status_code))
    mp.osd_message(API_ERROR_MESSAGE, 4)
  end
end

-- 获取用户名（延迟初始化）
local username = nil
local function get_username()
  if username then
    return username
  end
  
  local username_data = {}
  
  local info = mp_utils.file_info(USERNAME_FILE)
  if info and info.is_file then
    local file = io.open(USERNAME_FILE, "r")
    if file then
      local content = file:read("*all")
      file:close()
      username_data = mp_utils.parse_json(content) or {}
    end
  end
  
  local access_token = config.config.access_token
  if not access_token then
    mp.msg.error("BGM_ACCESS_TOKEN not found")
    return nil
  end
  
  if username_data[access_token] then
    username = username_data[access_token]
    return username
  end
  
  -- 从API获取用户名
  local res = M.get("/v0/me")
  if not res or res.status_code ~= 200 then
    mp.msg.error("Failed to get username from API")
    return nil
  end
  
  local fetched_username = res.body and res.body.username
  if fetched_username then
    username = fetched_username
    username_data[access_token] = username
    local file = io.open(USERNAME_FILE, "w")
    if file then
      file:write(mp_utils.format_json(username_data) or "{}")
      file:close()
    end
    return username
  end
  
  return nil
end

-- 获取默认headers
local function get_headers()
  return {
    ["accept"] = "application/json",
    ["User-Agent"] = "mpv_bangumi_sync/private",
    ["Authorization"] = "Bearer " .. (config.config.access_token or ""),
  }
end

local function get_proxy()
  return config.config.bgm_proxy
end

local function get_request_options(extra)
  local proxy = get_proxy()
  local opts = {
    headers = get_headers(),
    proxy = proxy,
    skip_cert_verify = proxy
      and proxy ~= ""
      and config.config.bgm_proxy_skip_cert_verify == true,
  }
  for key, value in pairs(extra or {}) do
    opts[key] = value
  end
  return opts
end

-- GET请求
function M.get(uri, params)
  local url = get_api_url() .. uri
  local res = http.get(url, get_request_options({
    params = params,
  }))
  
  if not res then
    warn_api_error(res)
    return {status_code = 500, body = {}}
  end

  warn_api_error(res)
  res.status_code = res.status_code or 200
  return res
end

-- POST请求
function M.post(uri, data)
  local url = get_api_url() .. uri
  local res = http.post(url, get_request_options({
    data = data,
  }))
  
  if not res then
    warn_api_error(res)
    return {status_code = 500, body = {}}
  end

  warn_api_error(res)
  res.status_code = res.status_code or 200
  return res
end

-- PUT请求
function M.put(uri, data)
  local url = get_api_url() .. uri
  local res = http.put(url, get_request_options({
    data = data,
  }))
  
  if not res then
    warn_api_error(res)
    return {status_code = 500, body = {}}
  end

  warn_api_error(res)
  res.status_code = res.status_code or 200
  return res
end

-- PATCH请求
function M.patch(uri, data, opts)
  local url = get_api_url() .. uri
  local res = http.patch(url, get_request_options({
    data = data,
    detach = opts and opts.detach or false,
  }))

  if not res then
    warn_api_error(res)
    return {status_code = 500, body = {}}
  end

  warn_api_error(res)
  res.status_code = res.status_code or 200
  return res
end

-- DELETE请求
function M.delete(uri)
  local url = get_api_url() .. uri
  local res = http.delete(url, get_request_options())

  if not res then
    warn_api_error(res)
    return {status_code = 500, body = {}}
  end

  warn_api_error(res)
  res.status_code = res.status_code or 200
  return res
end

-- 获取用户收藏
function M.get_user_collection(subject_id)
  local u = get_username()
  if not u then
    return {status_code = 401, body = {error = "Username not available"}}
  end
  return M.get(string.format("/v0/users/%s/collections/%d", u, subject_id))
end

-- 更新用户收藏
function M.update_user_collection(subject_id, status, private)
  status = status or 3
  private = private or false
  return M.post(
    string.format("/v0/users/-/collections/%d", subject_id),
    {type = status, private = private}
  )
end

-- 获取用户剧集
function M.get_user_episodes(subject_id)
  return M.get(
    string.format("/v0/users/-/collections/%d/episodes", subject_id),
    {offset = 0, limit = 1000, episode_type = 0}
  )
end

-- 获取剧集状态
function M.get_episode_status(episode_id)
  return M.get(string.format("/v0/users/-/collections/-/episodes/%d", episode_id))
end

-- 更新剧集状态
function M.update_episode_status(episode_id, status)
  status = status or 2
  return M.put(
    string.format("/v0/users/-/collections/-/episodes/%d", episode_id),
    {type = status}
  )
end

-- 批量更新剧集状态
function M.update_episodes_status(subject_id, episode_ids, status, opts)
  status = status or 2
  return M.patch(
    string.format("/v0/users/-/collections/%d/episodes", subject_id),
    {episode_id = episode_ids, type = status},
    opts
  )
end

-- 搜索条目
function M.search_subjects(keyword, opts)
  keyword = tostring(keyword or "")
  if keyword == "" then
    return {status_code = 400, body = {error = "keyword is empty"}}
  end
  opts = opts or {}
  local limit = tonumber(opts.limit) or 20
  local offset = tonumber(opts.offset) or 0
  local type_filter = opts.type_filter
  if type_filter == nil then
    type_filter = {2}
  end

  return M.post("/v0/search/subjects", {
    keyword = keyword,
    limit = limit,
    offset = offset,
    sort = opts.sort,
    filter = {
      type = type_filter,
    },
  })
end

-- 获取条目详情
function M.get_subject(subject_id)
  subject_id = tonumber(subject_id)
  if not subject_id then
    return {status_code = 400, body = {error = "invalid subject_id"}}
  end
  return M.get(string.format("/v0/subjects/%d", subject_id))
end

-- 获取用户名（延迟初始化）
function M.get_username()
  return get_username()
end

return M

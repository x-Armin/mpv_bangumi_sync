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

local API_URL = "https://api.bgm.tv"
local USERNAME_FILE = mp_utils.join_path(paths.DATA_PATH, "username.json")

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
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "mpv_bangumi_sync/private",
    ["Authorization"] = "Bearer " .. (config.config.access_token or ""),
  }
end

-- GET请求
function M.get(uri, params)
  local url = API_URL .. uri
  local res = http.get(url, {
    headers = get_headers(),
    params = params,
  })
  
  if not res then
    return {status_code = 500, body = {}}
  end
  
  mp.msg.verbose("bangumi_api GET response: " .. dump_for_log(res))
  res.status_code = res.status_code or 200
  return res
end

-- POST请求
function M.post(uri, data)
  local url = API_URL .. uri
  local res = http.post(url, {
    headers = get_headers(),
    data = data,
  })
  
  if not res then
    return {status_code = 500, body = {}}
  end
  
  mp.msg.verbose("bangumi_api POST response: " .. dump_for_log(res))
  res.status_code = res.status_code or 200
  return res
end

-- PUT请求
function M.put(uri, data)
  local url = API_URL .. uri
  local res = http.put(url, {
    headers = get_headers(),
    data = data,
  })
  
  if not res then
    return {status_code = 500, body = {}}
  end
  
  mp.msg.verbose("bangumi_api PUT response: " .. dump_for_log(res))
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

-- 获取用户名（延迟初始化）
function M.get_username()
  return get_username()
end

return M

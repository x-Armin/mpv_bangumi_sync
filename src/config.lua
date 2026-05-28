local opt = require "mp.options"

Options = {
  -- Bangumi访问令牌（必需）
  bgm_access_token = "",

  -- Bangumi API代理，留空表示不使用代理
  bgm_proxy = "",

  -- 新番存储目录（播放时即时同步）
  -- Windows用分号分隔多个目录，Linux/Mac用冒号分隔
  storages = "",

  -- 补番存储目录（退出播放/关闭播放器时批量同步）
  -- Windows用分号分隔多个目录，Linux/Mac用冒号分隔
  old_ani_storages = "",

  -- 自动点格子（开启/禁用）
  enable_auto_mark = true,

  -- 观看进度达到该比例时标记为“已看”（0~1）
  progress_mark_threshold = 0.9,
  batch_sync_threshold = 4,
}

local listeners = {}
local public_config = {}

local function normalize_string(value, default_value)
  if value == nil then
    return default_value
  end
  if type(value) ~= "string" then
    value = tostring(value)
  end
  value = value:match("^%s*(.-)%s*$")
  if value == "" then
    return default_value
  end
  return value
end

local function normalize_boolean(value, default_value)
  if value == nil then
    return default_value
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) == "string" then
    local lowered = value:lower()
    if lowered == "yes" or lowered == "true" or lowered == "1" or lowered == "on" then
      return true
    end
    if lowered == "no" or lowered == "false" or lowered == "0" or lowered == "off" then
      return false
    end
  end
  return default_value
end

local function clamp_progress_threshold(value, default_value)
  local num = tonumber(value)
  if not num or num <= 0 or num > 1 then
    return default_value
  end
  return num
end

local function clamp_batch_threshold(value, default_value)
  local num = tonumber(value)
  if not num then
    return default_value
  end
  num = math.floor(num)
  if num < 0 then
    return default_value
  end
  return num
end

-- 解析存储目录（支持多个目录）
local function parse_storages(storages_str)
  if not storages_str or storages_str == "" then
    return {}
  end
  
  local storages = {}
  local separator = mp.get_property_native("platform") == "windows" and ";" or ":"
  
  for storage in storages_str:gmatch("[^" .. separator .. "]+") do
    storage = storage:match("^%s*(.-)%s*$") -- trim
    if storage ~= "" then
      table.insert(storages, storage)
    end
  end
  
  return storages
end

local function merge_storages(primary, extra)
  local merged = {}
  local seen = {}
  for _, storage in ipairs(primary or {}) do
    if not seen[storage] then
      merged[#merged + 1] = storage
      seen[storage] = true
    end
  end
  for _, storage in ipairs(extra or {}) do
    if not seen[storage] then
      merged[#merged + 1] = storage
      seen[storage] = true
    end
  end
  return merged
end

local function apply_options()
  Options.bgm_access_token = normalize_string(Options.bgm_access_token, "")
  Options.bgm_proxy = normalize_string(Options.bgm_proxy, "")
  Options.storages = normalize_string(Options.storages, "")
  Options.old_ani_storages = normalize_string(Options.old_ani_storages, "")
  Options.enable_auto_mark = normalize_boolean(Options.enable_auto_mark, true)
  Options.storages_list = parse_storages(Options.storages)
  Options.old_ani_storages_list = parse_storages(Options.old_ani_storages)
  Options.all_storages_list = merge_storages(
    Options.storages_list,
    Options.old_ani_storages_list
  )
  Options.progress_mark_threshold = clamp_progress_threshold(
    Options.progress_mark_threshold,
    0.9
  )
  Options.batch_sync_threshold = clamp_batch_threshold(
    Options.batch_sync_threshold,
    4
  )

  -- 如果没有设置access_token，尝试从环境变量读取
  if not Options.bgm_access_token or Options.bgm_access_token == "" then
    Options.bgm_access_token = os.getenv("BGM_ACCESS_TOKEN") or ""
  end

  public_config.access_token = Options.bgm_access_token
  public_config.bgm_proxy = Options.bgm_proxy
  public_config.storages = Options.all_storages_list
  public_config.new_storages = Options.storages_list
  public_config.old_ani_storages = Options.old_ani_storages_list
end

local function notify_options_changed()
  for _, cb in ipairs(listeners) do
    local ok, err = pcall(cb, Options)
    if not ok then
      mp.msg.error("config listener error: " .. tostring(err))
    end
  end
end

opt.read_options(Options, mp.get_script_name(), function()
  apply_options()
  notify_options_changed()
end)

apply_options()


local M = {}

-- 配置对象
M.config = public_config

M.options = Options

function M.on_options_changed(cb)
  if type(cb) ~= "function" then
    return
  end
  listeners[#listeners + 1] = cb
end

return M

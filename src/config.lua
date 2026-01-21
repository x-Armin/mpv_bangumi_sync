local opt = require "mp.options"

Options = {
  -- Bangumi访问令牌（必需）
  bgm_access_token = "",

  -- 新番存储目录（播放时即时同步）
  -- Windows用分号分隔多个目录，Linux/Mac用冒号分隔
  storages = "",

  -- 补番存储目录（退出播放/关闭播放器时批量同步）
  -- Windows用分号分隔多个目录，Linux/Mac用冒号分隔
  catchup_storages = "",

  -- 观看进度达到该比例时标记为“已看”（0~1）
  progress_mark_threshold = 0.9,
}

opt.read_options(Options, mp.get_script_name(), function() end)

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

local function clamp_progress_threshold(value, default_value)
  local num = tonumber(value)
  if not num or num <= 0 or num > 1 then
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

-- 处理配置
Options.bgm_access_token = normalize_string(Options.bgm_access_token, "")
Options.storages = normalize_string(Options.storages, "")
Options.catchup_storages = normalize_string(Options.catchup_storages, "")
Options.storages_list = parse_storages(Options.storages)
Options.catchup_storages_list = parse_storages(Options.catchup_storages)
Options.all_storages_list = merge_storages(
  Options.storages_list,
  Options.catchup_storages_list
)
Options.progress_mark_threshold = clamp_progress_threshold(
  Options.progress_mark_threshold,
  0.9
)

-- 如果没有设置access_token，尝试从环境变量读取
if not Options.bgm_access_token or Options.bgm_access_token == "" then
  Options.bgm_access_token = os.getenv("BGM_ACCESS_TOKEN") or ""
end


local M = {}

-- 配置对象
M.config = {
  access_token = Options.bgm_access_token,
  storages = Options.all_storages_list,
  new_storages = Options.storages_list,
  catchup_storages = Options.catchup_storages_list,
}

M.options = Options

return M

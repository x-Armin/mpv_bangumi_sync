local opt = require "mp.options"

Options = {
  -- Bangumi访问令牌（必需）
  bgm_access_token = "",
  
  -- 番剧存储目录（插件只会在这些目录下激活）
  -- 可以设置多个目录，用分号分隔（Windows）或冒号分隔（Linux/Mac）
  storages = "",

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

-- 处理配置
Options.bgm_access_token = normalize_string(Options.bgm_access_token, "")
Options.storages = normalize_string(Options.storages, "")
Options.storages_list = parse_storages(Options.storages)
Options.progress_mark_threshold = clamp_progress_threshold(
  Options.progress_mark_threshold,
  0.9
)

-- 如果没有设置access_token，尝试从环境变量读取
if not Options.bgm_access_token or Options.bgm_access_token == "" then
  Options.bgm_access_token = os.getenv("BGM_ACCESS_TOKEN") or ""
end

return Options

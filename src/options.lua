local opt = require "mp.options"

Options = {
  -- Bangumi访问令牌（必需）
  bgm_access_token = "",
  
  -- 番剧存储目录（插件只会在这些目录下激活）
  -- 可以设置多个目录，用分号分隔（Windows）或冒号分隔（Linux/Mac）
  storages = "",
  
  -- dandanplay应用ID（可选，有默认值）
  dandanplay_appid = "",
  
  -- dandanplay应用密钥（可选）
  dandanplay_appsecret = "",
}

opt.read_options(Options, mp.get_script_name(), function() end)

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
Options.storages_list = parse_storages(Options.storages)

-- 如果没有设置access_token，尝试从环境变量读取
if not Options.bgm_access_token or Options.bgm_access_token == "" then
  Options.bgm_access_token = os.getenv("BGM_ACCESS_TOKEN") or ""
end

-- 如果没有设置dandanplay_appid，使用默认值
if not Options.dandanplay_appid or Options.dandanplay_appid == "" then
  Options.dandanplay_appid = os.getenv("DANDANPLAY_APPID") or "3tm7ddc5gh"
end

-- 如果没有设置dandanplay_appsecret，尝试从环境变量读取
if not Options.dandanplay_appsecret or Options.dandanplay_appsecret == "" then
  Options.dandanplay_appsecret = os.getenv("DANDANPLAY_APPSECRET") or ""
end

return Options

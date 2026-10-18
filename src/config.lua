local opt = require "mp.options"

local DEFAULT_BANGUMI_API = "https://api.bgm.tv"

Options = {
  -- Bangumi访问令牌（必需）
  bgm_access_token = "",

  -- Bangumi API URL
  bangumi_api = DEFAULT_BANGUMI_API,

  -- Bangumi API代理，留空表示不使用代理
  bgm_proxy = "",

  -- Skip TLS certificate verification when Bangumi API proxy is configured.
  bgm_proxy_skip_cert_verify = false,

  -- Comma separated hosts that should be treated as network files.
  network_file_hosts = "",

  -- Storage group 1. Use semicolon on Windows and colon on Linux/Mac.
  storage1 = "",

  -- Storage group 2. Use semicolon on Windows and colon on Linux/Mac.
  storage2 = "",

  -- 自动点格子（开启/禁用）
  enable_auto_mark = true,

  -- 最后一集同步后，全部正片已看时自动将条目标记为看过。
  enable_auto_complete = false,

  -- 观看进度达到该比例时标记为“已看”（0~1）
  progress_mark_threshold = 0.9,
  storage1_batch_sync_threshold = 1,
  storage2_batch_sync_threshold = 4,

  -- 番剧信息面板
  panel_res_x = 1700,          -- ASS 虚拟画布宽 (面板布局基准)
  panel_res_y = 1000,          -- ASS 虚拟画布高
  panel_auto_show = "no",      -- 匹配到剧集时自动弹出面板
  panel_dim_alpha = "90",      -- 背景压暗层透明度 (00 不透明 ~ FF 全透明)
  panel_mpv_path = "mpv",      -- 下载封面用的 mpv; "mpv" 时自动从 PATH/前端查找
  panel_cover_fill = "yes",    -- yes=封面裁剪填满; no=完整显示留同色边
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

local function normalize_bangumi_api(value)
  value = normalize_string(value, DEFAULT_BANGUMI_API)
  if not value:match("^https?://") then
    mp.msg.error("bangumi_api 配置无效，请使用完整 URL，例如 https://api.bgm.tv")
    mp.osd_message("bangumi_api 配置无效，请检查配置", 4)
    return DEFAULT_BANGUMI_API
  end
  return value:gsub("/+$", "")
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

-- ==== 番剧信息面板 (bangumi_info) ====
local panel_bool = function(v, def)
    if v == nil then return def end
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    if v == "yes" or v == "true" or v == "1" then return true end
    if v == "no" or v == "false" or v == "0" then return false end
    return def
end
local panel_num = function(v, lo, hi, def)
    local n = tonumber(v)
    if not n or n < lo or n > hi then return def end
    return math.floor(n)
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

local function parse_comma_list(value)
  if not value or value == "" then
    return {}
  end

  local list = {}
  local seen = {}
  for item in tostring(value):gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$")
    if item ~= "" then
      item = item:lower()
      if not seen[item] then
        list[#list + 1] = item
        seen[item] = true
      end
    end
  end
  return list
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

local function build_storage_groups()
  return {
    {
      key = "storage1",
      storages = Options.storage1_list,
      batch_sync_threshold = Options.storage1_batch_sync_threshold,
    },
    {
      key = "storage2",
      storages = Options.storage2_list,
      batch_sync_threshold = Options.storage2_batch_sync_threshold,
    },
  }
end

local function apply_options()
  Options.bgm_access_token = normalize_string(Options.bgm_access_token, "")
  Options.bangumi_api = normalize_bangumi_api(Options.bangumi_api)
  Options.bgm_proxy = normalize_string(Options.bgm_proxy, "")
  Options.bgm_proxy_skip_cert_verify = normalize_boolean(
    Options.bgm_proxy_skip_cert_verify,
    false
  )
  Options.network_file_hosts = normalize_string(Options.network_file_hosts, "")
  Options.storage1 = normalize_string(Options.storage1, "")
  Options.storage2 = normalize_string(Options.storage2, "")
  Options.enable_auto_mark = normalize_boolean(Options.enable_auto_mark, true)
  Options.enable_auto_complete = normalize_boolean(Options.enable_auto_complete, false)
  Options.storage1_list = parse_storages(Options.storage1)
  Options.storage2_list = parse_storages(Options.storage2)
  Options.network_file_hosts_list = parse_comma_list(Options.network_file_hosts)
  Options.all_storages_list = merge_storages(
    Options.storage1_list,
    Options.storage2_list
  )
  Options.progress_mark_threshold = clamp_progress_threshold(
    Options.progress_mark_threshold,
    0.9
  )
  Options.storage1_batch_sync_threshold = clamp_batch_threshold(
    Options.storage1_batch_sync_threshold,
    1
  )
  Options.storage2_batch_sync_threshold = clamp_batch_threshold(
    Options.storage2_batch_sync_threshold,
    4
  )
  Options.storage_groups = build_storage_groups()
  Options.panel = Options.panel or {}

  -- 番剧信息面板 (bangumi_info)
  local p = Options.panel
  p.res_x = panel_num(Options.panel_res_x, 320, 8192, 1700)
  p.res_y = panel_num(Options.panel_res_y, 240, 8192, 1000)
  p.auto_show = panel_bool(Options.panel_auto_show, false)
  p.dim_alpha = (function()
  local a = tostring(Options.panel_dim_alpha or "90"):lower()
    return a:match("^%x%x$") and a or "90"
  end)()
  p.mpv_path = tostring(Options.panel_mpv_path or "mpv"):match("^%s*(.-)%s*$") or "mpv"
  p.cover_fill = panel_bool(Options.panel_cover_fill, true)
  public_config.panel = Options.panel

  -- 如果没有设置access_token，尝试从环境变量读取
  if not Options.bgm_access_token or Options.bgm_access_token == "" then
    Options.bgm_access_token = os.getenv("BGM_ACCESS_TOKEN") or ""
  end

  public_config.access_token = Options.bgm_access_token
  public_config.bangumi_api = Options.bangumi_api
  public_config.bgm_proxy = Options.bgm_proxy
  public_config.bgm_proxy_skip_cert_verify = Options.bgm_proxy_skip_cert_verify
  public_config.network_file_hosts = Options.network_file_hosts_list
  public_config.storages = Options.all_storages_list
  public_config.storage1 = Options.storage1_list
  public_config.storage2 = Options.storage2_list
  public_config.storage_groups = Options.storage_groups
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

M.panel = public_config.panel

function M.on_options_changed(cb)
  if type(cb) ~= "function" then
    return
  end
  listeners[#listeners + 1] = cb
end

return M

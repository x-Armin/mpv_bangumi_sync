local mp_utils = require "mp.utils"

local M = {}

-- 获取mpv配置目录（portable_config或标准配置目录）
local function get_mpv_config_dir()
  -- 检查是否有portable_config
  local script_dir = mp.get_script_directory()
  if script_dir then
    -- 规范化路径
    script_dir = mp.command_native({"normalize-path", script_dir})
    -- 规范化路径分隔符为统一格式
    script_dir = script_dir:gsub("\\", "/")
    -- 获取scripts目录（支持正斜杠和反斜杠）
    local scripts_dir = script_dir:match("^(.+)[/\\][^/\\]+$")
    mp.msg.verbose("get_mpv_config_dir: scripts_dir is " .. tostring(scripts_dir))
    if scripts_dir then
      local portable_config = scripts_dir:match("^(.+)[/\\][^/\\]+$")
      portable_config = mp.command_native({"normalize-path", portable_config})
      local info = mp_utils.file_info(portable_config)
      if info and info.is_dir then
        return portable_config
      end
    end
  end
  
  -- 使用标准配置目录
  local platform = mp.get_property_native("platform")
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  
  if not home or home == "" then
    mp.msg.error("无法确定用户主目录")
    return nil
  end
  
  if platform == "windows" then
    local p = mp_utils.join_path(home, "AppData")
    p = mp_utils.join_path(p, "Roaming")
    p = mp_utils.join_path(p, "mpv")
    return p
  else
    local p = mp_utils.join_path(home, ".config")
    p = mp_utils.join_path(p, "mpv")
    return p
  end
end

-- 获取数据目录（用于存储缓存和数据库）
function M.get_data_path()
  local config_dir = get_mpv_config_dir()
  mp.msg.verbose("get_data_path: config_dir is " .. tostring(config_dir))
  if not config_dir then
    return nil
  end
  return mp_utils.join_path(config_dir, "mpv_bangumi_sync_data")
end

-- 确保目录存在
function M.ensure_dir(path)
  if not path or path == "" then
    mp.msg.error("ensure_dir: path is nil or empty")
    return
  end
  
  -- 规范化路径分隔符
  path = path:gsub("\\", "/")
  
  -- 检查目录是否已存在
  local info = mp_utils.file_info(path)
  if info and info.is_dir then
    return
  end
  
  -- 使用更简单的方法创建目录
  local platform = mp.get_property_native("platform")
  if platform == "windows" then
    -- Windows: 使用 mkdir 命令
    path = path:gsub("/", "\\")
    os.execute('if not exist "' .. path .. '" mkdir "' .. path .. '"')
  else
    -- Linux/Mac: 使用 mkdir -p
    os.execute('mkdir -p "' .. path .. '"')
  end
end

-- 初始化路径
local config_dir = get_mpv_config_dir()
if config_dir then
  M.DATA_PATH = M.get_data_path()
  if M.DATA_PATH then
    M.ensure_dir(M.DATA_PATH)
  else
    mp.msg.error("无法确定数据目录路径")
    M.DATA_PATH = ""
  end
else
  mp.msg.error("无法确定mpv配置目录")
  M.DATA_PATH = ""
end

return M

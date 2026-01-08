local mp_utils = require "mp.utils"

local M = {}

-- 计算文件MD5 hash（只读取前16MB）
function M.get_hash(video_path)
  local platform = mp.get_property_native("platform")
  
  if platform == "windows" then
    -- Windows: 使用PowerShell脚本文件，避免路径转义问题
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    local temp_file = mp_utils.join_path(temp_dir, "mpv_bangumi_sync_md5_" .. os.time() .. "_" .. math.random(10000) .. ".ps1")
    
    -- 转义路径中的单引号和美元符号
    local escaped_path = video_path:gsub("'", "''"):gsub("%$", "`$")
    -- 使用UTF-8编码写入脚本文件
    local ps_script = string.format(
      "$path=[System.IO.Path]::GetFullPath('%s');$fs=[System.IO.File]::OpenRead($path);$bytes=New-Object byte[] 16777216;$count=$fs.Read($bytes,0,16777216);$fs.Close();$md5=[System.Security.Cryptography.MD5]::Create();$hash=$md5.ComputeHash($bytes,0,$count);[System.BitConverter]::ToString($hash).Replace('-','').ToUpper()",
      escaped_path:gsub("\\", "/")
    )
    
    -- 使用UTF-8 with BOM写入脚本文件（PowerShell需要）
    local script_file = io.open(temp_file, "wb")
    if not script_file then
      mp.msg.error("Failed to create temporary PowerShell script")
      return ""
    end
    
    -- 写入UTF-8 BOM
    script_file:write("\239\187\191")
    script_file:write(ps_script)
    script_file:close()
    
    local result = mp.command_native({
      name = "subprocess",
      args = {"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", temp_file},
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
    })
    
    -- 清理临时文件
    os.remove(temp_file)
    
    if result.status == 0 and result.stdout then
      local hash = result.stdout:match("^%s*(.-)%s*$"):upper()
      if hash and hash ~= "" and #hash == 32 then
        mp.msg.info("MD5 hash calculated: " .. hash)
        return hash
      end
    end
    
    -- 如果失败，输出错误信息
    if result and result.stderr then
      mp.msg.verbose("MD5 calculation error: " .. result.stderr)
    end
  else
    -- Linux/Mac: 使用系统命令
    local result = mp.command_native({
      name = "subprocess",
      args = {"sh", "-c", "head -c 16777216 '" .. video_path:gsub("'", "'\\''") .. "' | md5sum | cut -d' ' -f1"},
      playback_only = false,
      capture_stdout = true,
    })
    
    if result.status == 0 and result.stdout then
      local hash = result.stdout:match("^%s*(.-)%s*$"):upper()
      if hash and hash ~= "" then
        return hash
      end
    end
  end
  
  mp.msg.error("Failed to calculate file hash")
  return ""
end

-- 获取视频信息
function M.get_info(video_path)
  local file_info = mp_utils.file_info(video_path)
  if not file_info or not file_info.is_file then
    return nil
  end
  
  -- 从mpv获取视频信息（如果正在播放）
  local duration = mp.get_property_number("duration")
  local width = mp.get_property_number("width")
  local height = mp.get_property_number("height")
  
  -- 如果mpv没有这些信息，使用ffprobe
  if not duration or duration == 0 then
    duration = M.get_duration_ffprobe(video_path)
  end
  if not width or not height then
    local resolution = M.get_resolution_ffprobe(video_path)
    if resolution then
      width = resolution.width
      height = resolution.height
    end
  end
  
  local filename = video_path:match("([^/\\]+)$") or video_path
  filename = filename:match("^(.+)%.[^%.]+$") or filename
  
  return {
    hash = M.get_hash(video_path),
    duration = math.floor(duration or 0),
    filename = filename,
    size = file_info.size,
    resolution = {width or 0, height or 0},
  }
end

-- 使用ffprobe获取时长
function M.get_duration_ffprobe(video_path)
  local result = mp.command_native({
    name = "subprocess",
    args = {"ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", video_path},
    playback_only = false,
    capture_stdout = true,
  })
  
  if result.status == 0 and result.stdout then
    local duration = tonumber(result.stdout:match("^%s*(.-)%s*$"))
    if duration then
      return math.floor(duration)
    end
  end
  
  return 0
end

-- 使用ffprobe获取分辨率
function M.get_resolution_ffprobe(video_path)
  local result = mp.command_native({
    name = "subprocess",
    args = {"ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", video_path},
    playback_only = false,
    capture_stdout = true,
  })
  
  if result.status == 0 and result.stdout then
    local width, height = result.stdout:match("(%d+)x(%d+)")
    if width and height then
      return {width = tonumber(width), height = tonumber(height)}
    end
  end
  
  return nil
end

return M

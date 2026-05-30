local mp_utils = require "mp.utils"
local md5 = require "src.md5"

local M = {}

local HASH_LIMIT = 16 * 1024 * 1024
local HASH_CHUNK_SIZE = 64 * 1024

-- 计算文件MD5 hash（只读取前16MB）
function M.get_hash(video_path)
  if type(md5) ~= "table" or not md5.new then
    mp.msg.error("MD5 module is not available")
    return ""
  end

  local hash_path = mp.command_native({"normalize-path", video_path}) or video_path
  local file, err = io.open(hash_path, "rb")
  if not file then
    mp.msg.error("Failed to open file for hash: " .. tostring(err))
    return ""
  end

  local ok, hash = pcall(function()
    local ctx = md5.new()
    local remaining = HASH_LIMIT

    while remaining > 0 do
      local read_size = math.min(HASH_CHUNK_SIZE, remaining)
      local chunk = file:read(read_size)
      if not chunk or chunk == "" then
        break
      end

      ctx:update(chunk)
      remaining = remaining - #chunk
    end

    return ctx:finish():upper()
  end)

  file:close()

  if ok and hash and #hash == 32 then
    mp.msg.info("MD5 hash calculated: " .. hash)
    return hash
  end

  mp.msg.error("Failed to calculate file hash: " .. tostring(hash))
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

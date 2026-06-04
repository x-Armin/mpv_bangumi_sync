local mp_utils = require "mp.utils"
local md5 = require "src.md5"

local M = {}

local HASH_LIMIT = 16 * 1024 * 1024
local HASH_CHUNK_SIZE = 64 * 1024

local function calculate_md5_from_chunks(read_chunk)
  if type(md5) ~= "table" or not md5.new then
    mp.msg.error("MD5 module is not available")
    return ""
  end

  local ok, hash = pcall(function()
    local ctx = md5.new()
    local remaining = HASH_LIMIT

    while remaining > 0 do
      local read_size = math.min(HASH_CHUNK_SIZE, remaining)
      local chunk = read_chunk(read_size)
      if not chunk or chunk == "" then
        break
      end

      ctx:update(chunk)
      remaining = remaining - #chunk
    end

    return ctx:finish():upper()
  end)

  if ok and hash and #hash == 32 then
    mp.msg.info("MD5 hash calculated: " .. hash)
    return hash
  end

  mp.msg.error("Failed to calculate file hash: " .. tostring(hash))
  return ""
end

local function url_decode(str)
  if not str then
    return nil
  end
  str = tostring(str):gsub("+", " ")
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function strip_extension(filename)
  return (filename and filename:match("^(.+)%.[^%.]+$")) or filename
end

local function get_url_filename(url)
  if not url or url == "" then
    return nil
  end
  local without_fragment = tostring(url):gsub("#.*$", "")
  local without_query = without_fragment:gsub("%?.*$", "")
  local tail = without_query:match("([^/\\]+)$")
  tail = url_decode(tail)
  if not tail or tail == "" then
    tail = mp.get_property("media-title") or mp.get_property("filename")
  end
  return strip_extension(tail or url)
end

local function get_current_resolution()
  local width = mp.get_property_number("width") or 0
  local height = mp.get_property_number("height") or 0
  return {width, height}
end

-- 计算文件MD5 hash（只读取前16MB）
function M.get_hash(video_path)
  local hash_path = mp.command_native({"normalize-path", video_path}) or video_path
  local file, err = io.open(hash_path, "rb")
  if not file then
    mp.msg.error("Failed to open file for hash: " .. tostring(err))
    return ""
  end

  local hash = calculate_md5_from_chunks(function(read_size)
    return file:read(read_size)
  end)
  file:close()
  return hash
end

function M.get_hash_from_url(url)
  local result = mp.command_native({
    name = "subprocess",
    args = {"curl", "-L", "-s", "-S", "--range", "0-16777215", tostring(url)},
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })
  if not result or result.status ~= 0 then
    mp.msg.error("Failed to fetch URL range for hash: " .. tostring(result and result.stderr or ""))
    return ""
  end

  local data = result.stdout or ""
  local offset = 1
  return calculate_md5_from_chunks(function(read_size)
    if offset > #data then
      return nil
    end
    local chunk = data:sub(offset, offset + read_size - 1)
    offset = offset + #chunk
    return chunk
  end)
end

function M.get_url_content_length(url)
  local result = mp.command_native({
    name = "subprocess",
    args = {"curl", "-L", "-s", "-S", "-I", tostring(url)},
    playback_only = false,
    capture_stdout = true,
    capture_stderr = true,
  })
  if not result or result.status ~= 0 or not result.stdout then
    return 0
  end

  local size = nil
  for value in result.stdout:gmatch("[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:%s*(%d+)") do
    size = tonumber(value) or size
  end
  return size or 0
end

function M.build_info(fields)
  fields = fields or {}
  return {
    hash = fields.hash or "",
    duration = math.floor(tonumber(fields.duration) or 0),
    filename = fields.filename or "",
    size = tonumber(fields.size) or 0,
    resolution = fields.resolution or {0, 0},
  }
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
  filename = strip_extension(filename)
  
  return M.build_info({
    hash = M.get_hash(video_path),
    duration = math.floor(duration or 0),
    filename = filename,
    size = file_info.size,
    resolution = {width or 0, height or 0},
  })
end

function M.get_url_info(url)
  local filename = get_url_filename(url)
  return M.build_info({
    hash = M.get_hash_from_url(url),
    duration = mp.get_property_number("duration") or 0,
    filename = filename,
    size = M.get_url_content_length(url),
    resolution = get_current_resolution(),
  })
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

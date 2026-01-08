local http = require "src.http"
local mp_utils = require "mp.utils"
local config = require "src.config"

local M = {}

local BASE_API = "https://api.dandanplay.net/api/v2/"

-- 获取appid和secret
-- local appid = config.config.dandanplay_appid or "****"
-- local secret = config.config.dandanplay_appsecret or "********"
local appid = ""
local secret = ""

-- 生成SHA256签名 (返回Hex字符串)
local function sha256(data)
  local platform = mp.get_property_native("platform")
  
  if platform == "windows" then
    -- Windows: 使用PowerShell
    -- 转义单引号
    local escaped_data = data:gsub("'", "''")
    local ps_cmd = string.format(
      "$bytes = [System.Text.Encoding]::UTF8.GetBytes('%s'); $sha256 = [System.Security.Cryptography.SHA256]::Create(); $hash = $sha256.ComputeHash($bytes); [System.BitConverter]::ToString($hash).Replace('-', '').ToLower()",
      escaped_data:gsub("\\", "\\\\")
    )
    
    local result = mp.command_native({
      name = "subprocess",
      args = {"powershell", "-NoProfile", "-Command", ps_cmd},
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
    })
    
    if result.status == 0 and result.stdout then
      local hash = result.stdout:match("^%s*(.-)%s*$"):lower()
      if hash and hash ~= "" then
        return hash
      end
    end
  else
    -- Linux/Mac: 使用系统命令
    local escaped_data = data:gsub("'", "'\\''")
    local result = mp.command_native({
      name = "subprocess",
      args = {"sh", "-c", "echo -n '" .. escaped_data .. "' | sha256sum | cut -d' ' -f1"},
      playback_only = false,
      capture_stdout = true,
    })
    
    if result.status == 0 and result.stdout then
      local hash = result.stdout:match("^%s*(.-)%s*$"):lower()
      if hash and hash ~= "" then
        return hash
      end
    end
  end
  
  mp.msg.error("Failed to calculate SHA256")
  return ""
end

-- Hex字符串转Base64 (用于签名)
local function hex_to_base64(hex)
  local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local binary = ""
  
  -- Hex 转 Binary String
  for i = 1, #hex, 2 do
    local byte_hex = hex:sub(i, i+1)
    local byte = tonumber(byte_hex, 16)
    if byte then
      binary = binary .. string.char(byte)
    end
  end
  
  local result = ""
  for i = 1, #binary, 3 do
    local a = string.byte(binary, i)
    local b = string.byte(binary, i+1) or 0
    local c = string.byte(binary, i+2) or 0
    
    -- 组合3个字节(24位)
    local buffer = a * 0x10000 + b * 0x100 + c
    
    local encoded = ""
    -- 拆分每6位索引
    encoded = encoded .. b64chars:sub(math.floor(buffer / 0x40000) % 64 + 1, math.floor(buffer / 0x40000) % 64 + 1)
    encoded = encoded .. b64chars:sub(math.floor(buffer / 0x1000) % 64 + 1, math.floor(buffer / 0x1000) % 64 + 1)
    encoded = encoded .. b64chars:sub(math.floor(buffer / 0x40) % 64 + 1, math.floor(buffer / 0x40) % 64 + 1)
    encoded = encoded .. b64chars:sub(buffer % 64 + 1, buffer % 64 + 1)
    
    -- 处理Padding
    if not string.byte(binary, i+1) then
      encoded = encoded:sub(1, 2) .. "=="
    elseif not string.byte(binary, i+2) then
      encoded = encoded:sub(1, 3) .. "="
    end
    
    result = result .. encoded
  end
  
  return result
end

-- 生成签名
local function generate_signature(timestamp, path)
  local data = appid .. timestamp .. path .. secret
  local hash_hex = sha256(data)
  -- 关键修正：将SHA256的Hex字符串转为Raw Bytes后再Base64编码
  return hex_to_base64(hash_hex)
end

-- POST请求
function M.post(uri, data, timestamp)
  timestamp = timestamp or os.time()
  local path = "/api/v2/" .. uri
  local sig = generate_signature(timestamp, path)
  
  local headers = {
    ["Accept"] = "application/json",
    ["X-AppId"] = appid,
    ["X-signature"] = sig,
    ["X-Timestamp"] = tostring(timestamp),
  }
  
  local url = BASE_API .. uri
  return http.post(url, {
    headers = headers,
    data = data,
  })
end

-- GET请求
function M.get(uri, params)
  local timestamp = os.time()
  local path = "/api/v2/" .. uri
  local sig = generate_signature(timestamp, path)
  
  local headers = {
    ["Accept"] = "application/json",
    ["X-AppId"] = appid,
    ["X-signature"] = sig,
    ["X-Timestamp"] = tostring(timestamp),
  }
  
  local url = BASE_API .. uri
  return http.get(url, {
    headers = headers,
    params = params,
  })
end

-- 匹配视频
function M.match(video_info)
  local data = {
    fileName = video_info.filename,
    fileHash = video_info.hash,
    fileSize = video_info.size,
    videoDuration = video_info.duration,
    matchMode = "hashAndFileName",
  }
  
  mp.msg.verbose("Match info: " .. video_info.filename .. " " .. video_info.hash) 
  local res = M.post("match", data)
  
  if not res or not res.body or not res.body.success then
    mp.msg.verbose("Match failed or no success flag")
    return {}
  end
  
  return res.body.matches or {}
end

-- 获取anime信息
function M.get_anime_info(anime_id)
  local res = M.get("bangumi/" .. tostring(anime_id))
  if not res or not res.body or not res.body.success then
    mp.msg.error("Failed to get anime info: " .. (res.body and res.body.errorMessage or "unknown"))
    return nil
  end
  
  return res.body.bangumi
end

-- 搜索anime
function M.search_anime(keyword, type_)
  local params = {keyword = keyword}
  if type_ then
    params.type = type_
  end
  
  local res = M.get("search/anime", params)
  if not res or not res.body then
    return {}
  end
  
  return res.body.animes or {}
end

return M

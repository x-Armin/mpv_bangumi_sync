local http = require "src.http"

local M = {}

local BASE_API = "https://api.dandanplay.net/api/v2/"

local appid_enc = "43ee637dcf24b626fcb6"
local secret_enc = "02ec7f1fdb38bd75e28cd8fdc4cb9eb6ae04ac574de37e33dd74543e22a01439"

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

local bit = require("bit")

local function xorshift32(x)
  x = bit.bxor(x, bit.lshift(x, 13))
  x = bit.bxor(x, bit.rshift(x, 17))
  x = bit.bxor(x, bit.lshift(x, 5))
  return bit.band(x, 0xffffffff)
end

local function hex_to_bytes(hex)
  local bytes = {}
  for i = 1, #hex, 2 do
    bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
  end
  return bytes
end

local function xor_stream_bytes(input_bytes, seed_u32)
  local out = {}
  local s = bit.band(seed_u32, 0xffffffff)

  for i = 1, #input_bytes do
    s = xorshift32(s)
    local k = bit.band(s, 0xff)
    out[i] = bit.bxor(input_bytes[i], k)
  end

  return out
end

local function decode_hex(hex, seed_u32)
  local bytes = hex_to_bytes(hex)
  local dec_bytes = xor_stream_bytes(bytes, seed_u32)
  local out = {}
  for i = 1, #dec_bytes do
    out[i] = string.char(dec_bytes[i])
  end
  return table.concat(out)
end

local SEED = 0xC0FFEE

local function generate_signature(timestamp, path)
  local data = decode_hex(appid_enc, SEED) .. timestamp .. path .. decode_hex(secret_enc, SEED)
  local hash_hex = sha256(data)
  return hex_to_base64(hash_hex)
end

-- POST请求
function M.post(uri, data, timestamp)
  timestamp = timestamp or os.time()
  local path = "/api/v2/" .. uri
  local sig = generate_signature(timestamp, path)
  
  local headers = {
    ["Accept"] = "application/json",
    ["X-AppId"] = decode_hex(appid_enc, SEED),
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
    ["X-AppId"] = decode_hex(appid_enc, SEED),
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

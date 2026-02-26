local mp_utils = require "mp.utils"
local M = {}

function M.table_merge(dest, source, forceOverride)
  if not dest or not source then
    return dest
  end
  for k, v in pairs(source) do
    if
      (not forceOverride and type(v) == "table" and type(dest[k])) == "table"
    then
      -- don't overwrite one table with another
      -- instead merge them recurisvely
      M.table_merge(dest[k], v)
    else
      dest[k] = v
    end
  end
  return dest
end

function M.file_exists(filename)
  local file_info = mp_utils.file_info(filename)
  return file_info and file_info.is_file
end

-- 对mpv subprocess 命令的封装
---@param args table
function M.subprocess_wrapper(args)
  ---检查并返回subprocess的stdout结果(必须为json)
  ---@param result any
  -- ---@return table?
  local check_result = function(result)
    if result.status ~= 0 then
      mp.msg.error("subprocess 执行失败: status=" .. result.status)
      return nil
    end

    if not result.stdout or result.stdout == "" then
      mp.msg.verbose "stdout为空"
      return {}
    end

    local json_result = mp_utils.parse_json(result.stdout)
    if not json_result then
      mp.msg.error("解析JSON失败: " .. result.stdout)
      return nil
    end

    return json_result
  end

  local function async(cb)
    cb = cb or {}
    cb.resp = cb.resp or function(_) end
    cb.err = cb.err or function() end

    mp.command_native_async({
      name = "subprocess",
      args = args,
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
    }, function(success, result, error)
      if not success or not result or result.status ~= 0 then
        local exit_code = (result and result.status or "unknown")
        local message = error
          or (result and result.stdout .. result.stderr)
          or ""
        mp.msg.error(
          "Calling failed. Exit code: " .. exit_code .. " Error: " .. message
        )
        cb.err()
        return
      end
      local json_result = check_result(result)
      cb.resp(json_result)
    end)
  end

  return {
    execute = function()
      local result = mp.command_native {
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
      }
      return check_result(result)
    end,
    async = async,
  }
end

function M.subprocess_err()
  return {
    execute = function()
      return nil
    end,
    async = function(cb)
      if cb and cb.err then
        cb.err()
      end
    end,
  }
end

function M.is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

-- 简单的JSON格式化（用于HTTP请求）
function M.format_json(data)
  local mp_utils = require "mp.utils"
  if mp_utils.format_json then
    return mp_utils.format_json(data)
  end
  -- 简单的JSON编码（仅处理基本类型）
  if type(data) == "table" then
    local parts = {}
    for k, v in pairs(data) do
      local key = type(k) == "string" and string.format('"%s"', k) or tostring(k)
      local value
      if type(v) == "string" then
        value = string.format('"%s"', v:gsub('"', '\\"'))
      elseif type(v) == "table" then
        value = M.format_json(v)
      else
        value = tostring(v)
      end
      table.insert(parts, string.format("%s: %s", key, value))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "{}"
end

-- 字符串trim函数
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local NOISE_TAGS = {
  ["aac"] = true,
  ["ac3"] = true,
  ["av1"] = true,
  ["bd"] = true,
  ["bdrip"] = true,
  ["baha"] = true,
  ["bits"] = true,
  ["ddp5"] = true,
  ["flac"] = true,
  ["h264"] = true,
  ["h265"] = true,
  ["hevc"] = true,
  ["webrip"] = true,
  ["webdl"] = true,
  ["web-dl"] = true,
  ["x264"] = true,
  ["x265"] = true,
}

local function normalize_brackets(text)
  if not text then
    return nil
  end
  return text
    :gsub("（", "(")
    :gsub("）", ")")
    :gsub("【", "[")
    :gsub("】", "]")
end

local function normalize_episode_number(ep_text, allow_large)
  local ep = tonumber(ep_text)
  if not ep then
    return nil
  end
  ep = math.floor(ep)
  if ep <= 0 then
    return nil
  end
  if allow_large then
    if ep > 10000 then
      return nil
    end
  else
    if ep > 500 then
      return nil
    end
    if ep >= 1900 and ep <= 2099 then
      return nil
    end
  end
  return ep
end

local function is_noise_token(token)
  if not token or token == "" then
    return true
  end
  local t = token:lower()
  t = t:gsub("^[%[%]%(%){}%+%-_%.]+", ""):gsub("[%[%]%(%){}%+%-_%.]+$", "")
  if t == "" then
    return true
  end
  if NOISE_TAGS[t] then
    return true
  end
  if t:match("^%d%d%d?%d?[pPkK]$") then
    return true
  end
  if t:match("^%d+[xX]%d+$") then
    return true
  end
  if t:match("^10bit$") or t:match("^8bit$") then
    return true
  end
  return false
end

local function split_tokens(text)
  local tokens = {}
  local normalized = text
    :gsub("[_%.]", " ")
    :gsub("　", " ")
  for token in normalized:gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

local function segment_has_episode_hint(segment)
  if not segment then
    return false
  end
  if segment:match("第%s*%d+%s*[集话回話]") then
    return true
  end
  if segment:match("[sS]%d+[%.%-%s_]*[eE][pP]?%d+") then
    return true
  end
  if segment:match("[eE][pP]?%d+") then
    return true
  end
  if segment:match("%d+%s*[xX]%s*%d+") then
    return true
  end
  return false
end

local function segment_is_noise(segment)
  if not segment or segment == "" then
    return true
  end
  if segment_has_episode_hint(segment) then
    return false
  end
  local inner = segment
  local first = inner:sub(1, 1)
  if first == "[" or first == "(" then
    inner = inner:sub(2)
  end
  local last = inner:sub(-1)
  if last == "]" or last == ")" then
    inner = inner:sub(1, -2)
  end
  local tokens = split_tokens(inner)
  if #tokens == 0 then
    return true
  end
  for _, token in ipairs(tokens) do
    if not is_noise_token(token) then
      return false
    end
  end
  return true
end

local function strip_noise_segments(text)
  local stripped = normalize_brackets(text) or ""
  stripped = stripped:gsub("%b[]", function(seg)
    if segment_is_noise(seg) then
      return " "
    end
    return seg
  end)
  stripped = stripped:gsub("%b()", function(seg)
    if segment_is_noise(seg) then
      return " "
    end
    return seg
  end)
  return stripped
end

local function extract_episode_from_text(text)
  if not text or text == "" then
    return nil
  end

  text = normalize_brackets(trim(text))
  text = strip_noise_segments(text)
  if text == "" then
    return nil
  end

  local ep = normalize_episode_number(text:match("第%s*0*(%d+)%s*[集话回話]"), true)
  if ep then
    return ep
  end

  ep = normalize_episode_number(text:match("[sS]%d+[%.%-%s_]*[eE][pP]?%s*0*(%d+)"), true)
  if ep then
    return ep
  end

  local _, x_ep = text:match("(%d+)%s*[xX]%s*0*(%d+)")
  ep = normalize_episode_number(x_ep, true)
  if ep then
    return ep
  end

  local tokens = split_tokens(text)
  local tail_number = nil
  for i, raw_token in ipairs(tokens) do
    local token = raw_token:gsub("^[%({]+", ""):gsub("[%)}]+$", "")

    ep = normalize_episode_number(token:match("^%[0*(%d+)%]$"), false)
    if ep then
      return ep
    end

    ep = normalize_episode_number(token:match("^%-0*(%d+)$"), false)
    if ep then
      return ep
    end

    ep = normalize_episode_number(token:match("^[eE][pP]?0*(%d+)[vV]?%d*$"), true)
    if ep then
      return ep
    end

    ep = normalize_episode_number(token:match("^0*(%d+)[集话回話]$"), true)
    if ep then
      return ep
    end

    local _, token_x_ep = token:match("^(%d+)[xX]0*(%d+)$")
    ep = normalize_episode_number(token_x_ep, true)
    if ep then
      return ep
    end

    local pure_num = normalize_episode_number(token:match("^0*(%d+)$"), false)
    if pure_num then
      local prev = tokens[i - 1] and tokens[i - 1]:lower() or ""
      if prev == "-" or prev == "#" then
        return pure_num
      end
      tail_number = pure_num
    end
  end

  return tail_number
end

-- 从文件名提取信息（番剧名、集数等）
function M.extract_info_from_filename(filename)
  filename = normalize_brackets(filename or "")
  -- 移除文件扩展名
  filename = filename:match("^(.+)%.[^%.]+$") or filename
  filename = trim(filename)
  
  local tags = {}
  local title_parts = {}
  
  for seg in filename:gmatch("%b[]") do
    tags[#tags + 1] = trim(seg:sub(2, -2))
  end
  for seg in filename:gmatch("%b()") do
    tags[#tags + 1] = trim(seg:sub(2, -2))
  end

  -- 移除标签后的剩余部分
  local remaining = filename:gsub("%b[]", " "):gsub("%b()", " ")
  for part in remaining:gmatch("%S+") do
    table.insert(title_parts, trim(part))
  end
  
  -- 从标签中提取集数
  local episode = extract_episode_from_text(filename)
  for _, tag in ipairs(tags) do
    local ep_match = extract_episode_from_text(tag)
    if ep_match then
      episode = ep_match
      break
    end
  end
  
  -- 如果标签中没有，从标题部分提取
  if not episode then
    for i, part in ipairs(title_parts) do
      local ep_match = extract_episode_from_text(part)
      
      if ep_match then
        episode = ep_match
        -- 从标题部分移除集数
        title_parts[i] = part
          :gsub("第%s*%d+%s*[集话回話]", "")
          :gsub("[sS]%d+[%.%-%s_]*[eE][pP]?%s*%d+", "")
          :gsub("[eE][pP]?%s*%d+", "")
          :gsub("%d+%s*[xX]%s*%d+", "")
          :gsub("^%s*%[%d+%]%s*$", "")
          :gsub("^%-+%s*%d+$", "")
          :gsub("^%d+$", "")
        if trim(title_parts[i]) == "" then
          title_parts[i] = "-"
        end
        break
      end
    end
  end
  
  -- 清理标题部分
  local cleaned_parts = {}
  for _, part in ipairs(title_parts) do
    local trimmed = trim(part)
    if part ~= "-" and trimmed ~= "" then
      if not is_noise_token(trimmed) then
        table.insert(cleaned_parts, trimmed)
      end
    end
  end
  
  local title = #cleaned_parts > 0 and table.concat(cleaned_parts, " ") or nil
  
  return {
    title = title,
    tags = tags,
    episode = episode,
  }
end

-- 字符串相似度匹配（简单的编辑距离算法）
function M.fuzzy_match_title(t1, t2)
  if not t1 or not t2 or t1 == "" or t2 == "" then
    return 0.0
  end
  
  -- 简单的基于共同部分的相似度计算
  local parts1 = {}
  for part in t1:gmatch("%S+") do
    table.insert(parts1, part:lower())
  end
  
  local parts2 = {}
  for part in t2:gmatch("%S+") do
    table.insert(parts2, part:lower())
  end
  
  -- 计算共同部分
  local common = {}
  local parts1_set = {}
  for _, p in ipairs(parts1) do
    parts1_set[p] = true
  end
  
  for _, p in ipairs(parts2) do
    if parts1_set[p] then
      table.insert(common, p)
    end
  end
  
  -- 计算相似度
  local l1 = #table.concat(parts1, "")
  local l2 = #table.concat(parts2, "")
  local l_common = #table.concat(common, "")
  
  if l1 == 0 or l2 == 0 then
    return 0.0
  end
  
  local ratio1 = l_common / math.min(l1, l2)
  
  -- 简单的字符串相似度（基于字符匹配）
  local max_len = math.max(#t1, #t2)
  local matches = 0
  for i = 1, math.min(#t1, #t2) do
    if t1:sub(i, i):lower() == t2:sub(i, i):lower() then
      matches = matches + 1
    end
  end
  local ratio2 = matches / max_len
  
  return math.max(ratio1, ratio2)
end

return M

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

-- 从文件名提取信息（番剧名、集数等）
function M.extract_info_from_filename(filename)
  -- 移除文件扩展名
  filename = filename:match("^(.+)%.[^%.]+$") or filename
  filename = trim(filename)
  
  local tags = {}
  local title_parts = {}
  
  -- 提取标签 [xxx] (xxx) （xxx）【xxx】第x话
  local tag_pattern = "[%[%(%（【第](.-)[%]%）】话話]"
  for tag in filename:gmatch(tag_pattern) do
    table.insert(tags, trim(tag))
  end
  
  -- 移除标签后的剩余部分
  local remaining = filename:gsub(tag_pattern, " ")
  for part in remaining:gmatch("%S+") do
    table.insert(title_parts, trim(part))
  end
  
  -- 从标签中提取集数
  local episode = nil
  for _, tag in ipairs(tags) do
    -- 匹配数字（如 "1", "12v2", "12end"）
    local ep_match = tag:match("^(%d+)(v%d+)?(end)?$")
    if ep_match then
      episode = tonumber(ep_match)
      break
    end
    -- 匹配 ep_1, ep1 等
    ep_match = tag:match("^ep_?(%d+)")
    if ep_match then
      episode = tonumber(ep_match)
      break
    end
  end
  
  -- 如果标签中没有，从标题部分提取
  if not episode then
    for i, part in ipairs(title_parts) do
      -- 匹配 -ep1-, -s1e1-, -1-, 1- 等
      local ep_match = part:match("-?ep(%d+)-?") 
        or part:match("-?s%d+e(%d+)-?")
        or part:match("-?(%d+)(v%d+)?(end)?-?$")
        or part:match("^(%d+)$")
      
      if ep_match then
        episode = tonumber(ep_match)
        -- 从标题部分移除集数
        title_parts[i] = part:gsub("ep%d+", ""):gsub("s%d+e%d+", ""):gsub("%d+", "")
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
      table.insert(cleaned_parts, trimmed)
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

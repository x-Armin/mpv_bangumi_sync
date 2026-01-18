local utils = require "src.utils"

local M = {}

local UTF8_PATTERN = "[\1-\127\194-\244][\128-\191]*"
local CHINESE_NUM_MAP = {
  ["零"] = 0, ["一"] = 1, ["二"] = 2, ["三"] = 3, ["四"] = 4,
  ["五"] = 5, ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9,
  ["十"] = 10, ["百"] = 100, ["千"] = 1000, ["万"] = 10000,
}

local function chinese_to_number(cn)
  local total = 0
  local num = 0
  local unit = 1

  local chars = {}
  for uchar in cn:gmatch(UTF8_PATTERN) do
    table.insert(chars, 1, uchar)
  end

  for _, char in ipairs(chars) do
    local val = CHINESE_NUM_MAP[char]
    if val then
      if val >= 10 then
        if num == 0 then
          num = 1
        end
        unit = val
      else
        total = total + val * unit
        unit = 1
        num = 0
      end
    end
  end

  if unit > 1 then
    total = total + num * unit
  end

  if total > 0 then
    return total
  end
  return num
end

local function clean_name(name)
  return name:gsub("^%[.-%]", " ")
    :gsub("^%(.-%)", " ")
    :gsub("[_%.%[%]]", " ")
    :gsub("第%s*%d+%s*季", "")
    :gsub("第%s*%d+%s*部", "")
    :gsub("第[一二三四五六七八九十]+季", "")
    :gsub("第[一二三四五六七八九十]+部", "")
    :gsub("^%s*(.-)%s*$", "%1")
    :gsub("[!@#%.%?%+%-%%&*_=,/~`]+$", "")
end

local formatters = {
  {
    regex = "^(.-)%s*[_%-%.%s]%s*第%s*(%d+)%s*[季部]+%s*[_%-%.%s]%s*第%s*(%d+[%.v]?%d*)%s*[话集回]",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. season .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*第([一二三四五六七八九十]+)[季部]+%s*[_%-%.%s]%s*第%s*(%d+[%.v]?%d*)%s*[话集回]",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. chinese_to_number(season) .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*第%s*(%d+)%s*[季部]+%s*[_%-%.%s]%s*[^%ddD][eEpP]+(%d+[%.v]?%d*)",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. season .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*第([一二三四五六七八九十]+)[季部]+%s*[_%-%.%s]%s*[^%ddD][eEpP]+(%d+[%.v]?%d*)",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. chinese_to_number(season) .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)[_%.%s]%d%d[_%.%s]%d%d%s*[_%.%s]?(.-)%s*[_%.%s]%d+[pPkKxXbBfF]",
    format = function(name, year, subtitle)
      local title = clean_name(name)
      if subtitle then
        title = title .. ": " .. subtitle:gsub("%.", " "):gsub("^%s*(.-)%s*$", "%1")
      end
      return title .. " (" .. year .. ")"
    end
  },
  {
    regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)%s*[_%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+%.?%d*)",
    format = function(name, year, season, episode)
      return clean_name(name) .. " (" .. year .. ") S" .. season .. "E" .. episode
    end
  },
  {
    regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)%s*[_%.%s]%s*[^%ddD][eEpP]+(%d+%.?%d*)",
    format = function(name, year, episode)
      return clean_name(name) .. " (" .. year .. ") E" .. episode
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+[%.v]?%d*)%s*[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
    format = function(name, season, episode, year)
      return clean_name(name) .. " (" .. year .. ") S" .. season .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*[sS](%d+)[%.%-%s:]?[eE](%d+%.?%d*)",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. season .. "E" .. episode
    end
  },
  {
    regex = "^(.-)%s*[_%.%s]%s*(%d+)[nrdsth]+[_%.%s]%s*[sS]eason[_%.%s]%s*%[(%d+[%.v]?%d*)%]",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. season .. "E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[^%ddD][eEpP]+(%d+[%.v]?%d*)[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
    format = function(name, episode, year)
      return clean_name(name) .. " (" .. year .. ") E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[^%ddD][eEpP]+(%d+%.?%d*)",
    format = function(name, episode)
      return clean_name(name) .. " E" .. episode
    end
  },
  {
    regex = "^(.-)%s*第%s*(%d+[%.v]?%d*)%s*[话集回]",
    format = function(name, episode)
      return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*%[(%d+[%.v]?%d*)%]",
    format = function(name, episode)
      return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*%[(%d+[%.v]?%d*)%(%a+%)%]",
    format = function(name, episode)
      return clean_name(name) .. " E" .. episode:gsub("v%d+$", "")
    end
  },
  {
    regex = "^(.-)%s*[%-#]%s*(%d+%.?%d*)%s*",
    format = function(name, episode)
      return clean_name(name) .. " E" .. episode
    end
  },
  {
    regex = "^(.-)%s*[%[%(]([OVADSPs]+)[%]%)",
    format = function(name, sp)
      return clean_name(name) .. " [" .. sp .. "]"
    end
  },
  {
    regex = "^(.-)%s*[_%-%.%s]%s*(%d?%d)x(%d%d?%d?%d?)[^%dhHxXvVpPkKxXbBfF]",
    format = function(name, season, episode)
      return clean_name(name) .. " S" .. season .. "E" .. episode
    end
  },
  {
    regex = "^%((%d%d%d%d)%.?%d?%d?%.?%d?%d?%)%s*(.-)%s*[%(%[]",
    format = function(year, name)
      return clean_name(name) .. " (" .. year .. ")"
    end
  },
  {
    regex = "^(.-)%s*[_%.%s]%s*(%d%d%d%d)[^%dhHxXvVpPkKxXbBfF]",
    format = function(name, year)
      return clean_name(name) .. " (" .. year .. ")"
    end
  },
  {
    regex = "^%[.-%]%s*%[?(.-)%]?%s*[%(%[]",
    format = function(name)
      return clean_name(name)
    end
  },
}

local function format_filename(title)
  for _, formatter in ipairs(formatters) do
    local matches = {title:match(formatter.regex)}
    if #matches > 0 then
      title = formatter.format(unpack(matches))
      return title
    end
  end
  return nil
end

local function hex_to_char(x)
  return string.char(tonumber(x, 16))
end

local function url_decode(str)
  if str == nil then
    return nil
  end
  str = str:gsub('^%a[%a%d-_]+://', '')
           :gsub('^%a[%a%d-_]+:%?', '')
           :gsub('%%(%x%x)', hex_to_char)
  if str:find('://localhost:?') then
    str = str:gsub('^.*/', '')
  end
  str = str:gsub('%?.+', '')
           :gsub('%+', ' ')
  return str
end

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  if mp and mp.command_native then
    local ok, normalized = pcall(mp.command_native, {"normalize-path", path})
    if ok and normalized then
      return normalized
    end
  end
  return path
end

local function split_path(path)
  if not path or path == "" then
    return nil, nil
  end
  local normalized = normalize_path(path)
  normalized = normalized:gsub("\\", "/")
  local dir = normalized:match("^(.+)/[^/]+$")
  local filename = normalized:match("([^/]+)$")
  return dir, filename
end

local function get_parent_directory(path)
  if path and not utils.is_protocol(path) then
    return split_path(path)
  end
  return nil
end

local function title_replace(title)
  if not title then
    return nil
  end
  return title
    :gsub("%b[]", " ")
    :gsub("%b()", " ")
    :gsub("[_%.]", " ")
    :gsub("^%s*(.-)%s*$", "%1")
    :gsub("[@#%.%+%-%%&*_=,/~`]+$", "")
end

local function parse_title()
  local path = mp.get_property("path")
  local filename = mp.get_property("filename/no-ext")

  if not filename then
    return nil
  end
  local thin_space = string.char(0xE2, 0x80, 0x89)
  filename = filename:gsub(thin_space, " ")
  local media_title, season, episode = nil, nil, nil
  if path and not utils.is_protocol(path) then
    local title = format_filename(filename)
    if title then
      media_title, season, episode = title:match("^(.-)%s*[sS](%d+)[eE](%d+)")
      if season then
        return title_replace(media_title), season, episode
      else
        media_title, episode = title:match("^(.-)%s*[eE](%d+)")
        if episode then
          return title_replace(media_title), season, episode
        end
      end
      return title_replace(title)
    end

    local directory = get_parent_directory(path)
    if directory then
      local dir, title = split_path(directory)
      local title_str = title or ""
      local lower = title_str:lower()
      if lower:match("^%s*seasons?%s*%d+%s*$")
        or lower:match("^%s*specials?%s*$")
        or title_str:match("^%s*SPs?%s*$")
        or title_str:match("^%s*O[VAD]+s?%s*$")
        or title_str:match("^%s*第%s*%d+%s*[季部]+%s*$")
        or title_str:match("^%s*第[一二三四五六七八九十]+[季部]+%s*$") then
        if dir then
          directory = dir
          _, title = split_path(dir)
          title_str = title or ""
        end
      end
      title_str = title_str
        :gsub(thin_space, " ")
        :gsub("%[.-%]", "")
        :gsub("^%s*%(%d+.?%d*.?%d*%)", "")
        :gsub("%(%d+.?%d*.?%d*%)%s*$", "")
        :gsub("[%._]", " ")
        :gsub("^%s*(.-)%s*$", "%1")
      return title_replace(title_str)
    end
  end

  local title = mp.get_property("media-title")
  if title then
    title = title:gsub(thin_space, " ")
    local ftitle = url_decode(title) or title
    local name = ftitle:match("^(.-)%s*|%s*(.-)%s*$")
    if name then
      ftitle = name
    end
    local format_title = format_filename(ftitle)
    if format_title then
      media_title, season, episode = format_title:match("^(.-)%s*[sS](%d+)[eE](%d+)")
      if season then
        title = media_title
      else
        media_title, episode = format_title:match("^(.-)%s*[eE](%d+)")
        if episode then
          season = 1
          title = media_title
        else
          title = format_title
        end
      end
    end
  end

  return title_replace(title), season, episode
end

function M.get_default_search_query()
  local title = nil
  if mp and mp.get_property then
    title = select(1, parse_title())
  end
  if title and title ~= "" then
    return title
  end

  local path = mp.get_property("path")
  if not path then
    return nil
  end
  local filename = path:match("([^/\\]+)$") or path
  filename = filename:match("^(.+)%.[^%.]+$") or filename
  local cleaned = filename
  cleaned = cleaned:gsub("%b[]", "")
  cleaned = cleaned:gsub("%b()", "")
  cleaned = cleaned:gsub("[Ss]%d+[Ee]%d+", "")
  cleaned = cleaned:gsub("[Ee]%d+", "")
  cleaned = cleaned:gsub("_", " ")
  cleaned = cleaned:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  return cleaned ~= "" and cleaned or filename
end

return M

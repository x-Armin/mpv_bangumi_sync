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

local function url_tail_decode(str)
  str = url_decode(str)
  if not str then
    return nil
  end
  local last_pos = str:match(".*[/\\]()")
  if last_pos then
    str = str:sub(last_pos)
  end
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

local TITLE_WRAPPER_DELIMITERS = {
  "《", "》", "〈", "〉", "「", "」", "『", "』",
  "“", "”", "‘", "’", "（", "）", "【", "】",
  "〔", "〕", "［", "］", "｛", "｝", "〖", "〗",
}

local TITLE_NORMALIZE_SEPARATORS = {
  "：", "；", "，", "。", "、", "！", "？", "·", "・",
  "／", "＼", "｜", "＋", "＝", "＿", "～", "〜",
  "—", "–", "－", "…", "　",
}

local STREAM_RELEASE_SUFFIX_LITERALS = {
  "全集", "合集", "完结", "完結",
  "周更", "週更",
  "超清中字", "高清中字", "中文字幕", "中字",
  "未删减版", "未刪減版", "无删减版", "無刪減版",
}

local STREAM_RELEASE_SUFFIX_PATTERNS = {
  "全%s*%d+%s*集$",
  "全%s*[一二三四五六七八九十百千万]+%s*集$",
  "%d%d%d[pP]$",
  "%d%d%d%d[pP]$",
  "[248][kK]$",
}

local STREAM_RELEASE_TRAILING_SEPARATORS = "[%s_%.%-#@,，、/／~～:：|｜]+$"

local function replace_literals(value, literals, replacement)
  for _, literal in ipairs(literals) do
    value = value:gsub(literal, replacement or "")
  end
  return value
end

local function strip_stream_release_suffixes(title)
  if not title then
    return nil
  end

  local changed = true
  while changed do
    local before = title
    title = title:gsub(STREAM_RELEASE_TRAILING_SEPARATORS, "")

    for _, literal in ipairs(STREAM_RELEASE_SUFFIX_LITERALS) do
      title = title:gsub("%s*" .. literal .. "%s*$", "")
      title = title:gsub(STREAM_RELEASE_TRAILING_SEPARATORS, "")
    end

    for _, pattern in ipairs(STREAM_RELEASE_SUFFIX_PATTERNS) do
      title = title:gsub("%s*" .. pattern, "")
      title = title:gsub(STREAM_RELEASE_TRAILING_SEPARATORS, "")
    end

    changed = title ~= before
  end

  return title
end

local function title_replace(title)
  if not title then
    return nil
  end
  title = title
    :gsub("^%s*【%s*[一四七十]月%s*】", " ")
    :gsub("^%s*【%s*%d+月%s*】", " ")
    :gsub("^%s*%[%s*[一四七十]月%s*%]", " ")
    :gsub("^%s*%[%s*%d+月%s*%]", " ")
    :gsub("%s*【[A-Za-z0-9%-%+_%. ]+】%s*$", " ")

  title = replace_literals(title, TITLE_WRAPPER_DELIMITERS, " ")

  title = title
    :gsub("%b[]", " ")
    :gsub("%b()", " ")
    :gsub("[_%.]", " ")

  title = strip_stream_release_suffixes(title)

  return title
    :gsub("^%s*(.-)%s*$", "%1")
    :gsub("[@#%.%+%-%%&*_=,/~`]+$", "")
end

local function trim(value)
  if not value then
    return nil
  end
  return tostring(value):match("^%s*(.-)%s*$")
end

local function strip_stream_title_suffix(text)
  if not text then
    return nil
  end

  local patterns = {
    "%s+%-+%s*Anime1%.me.*$",
    "%s+–%s*Anime1%.me.*$",
    "%s+—%s*Anime1%.me.*$",
    "%s+|%s*Anime1%.me.*$",
    "%s+%-+%s*TV番组.*$",
    "%s+–%s*TV番组.*$",
    "%s+—%s*TV番组.*$",
    "%s+%-+%s*次元城动画.*$",
    "%s+–%s*次元城动画.*$",
    "%s+—%s*次元城动画.*$",
    "%s+%-+%s*连载新番%s*%-+%s*吐槽弹幕网.*$",
    "%s+–%s*连载新番%s*–%s*吐槽弹幕网.*$",
    "%s+—%s*连载新番%s*—%s*吐槽弹幕网.*$",
    "%s+%-+%s*吐槽弹幕网.*$",
    "%s+–%s*吐槽弹幕网.*$",
    "%s+—%s*吐槽弹幕网.*$",
  }
  for _, pattern in ipairs(patterns) do
    text = text:gsub(pattern, "")
  end
  return trim(text)
end

local function normalize_title(title)
  title = title_replace(title)
  if not title or title == "" then
    return nil
  end
  local normalized = title:lower()
  normalized = normalized:gsub("　", "")
  normalized = replace_literals(normalized, TITLE_NORMALIZE_SEPARATORS, "")
  normalized = normalized:gsub("[%s%p_%-]+", "")
  return normalized ~= "" and normalized or nil
end

local function parse_number(value, opts)
  if value == nil then
    return nil
  end
  local num = tonumber(tostring(value):match("(%d+%.?%d*)"))
  if not num or num < 0 then
    return nil
  end
  if num == 0 and not (opts and opts.allow_zero) then
    return nil
  end
  return math.floor(num)
end

local function parse_season_hint(text)
  if not text then
    return nil
  end
  local season = text:match("[sS]%s*0*(%d+)[%.%-%s_:]*[eE]")
    or text:match("第%s*(%d+)%s*[季部]")
  if season then
    return parse_number(season)
  end
  local cn_season = text:match("第([一二三四五六七八九十]+)[季部]")
  if cn_season then
    return chinese_to_number(cn_season)
  end
  return nil
end

local function parse_formatted_title(format_title)
  if not format_title then
    return nil, nil, nil
  end
  local media_title, season, episode = format_title:match("^(.-)%s*[sS](%d+)[eE](%d+%.?%d*)")
  if season then
    return title_replace(media_title), parse_number(season), parse_number(episode, {allow_zero = true})
  end

  media_title, episode = format_title:match("^(.-)%s*[eE](%d+%.?%d*)")
  if episode then
    return title_replace(media_title), nil, parse_number(episode, {allow_zero = true})
  end

  return title_replace(format_title), nil, nil
end

local function build_title_info(title, season, episode, source, raw_title)
  title = title_replace(title)
  if not title or title == "" then
    return nil
  end

  local normalized = normalize_title(title)
  if not normalized then
    return nil
  end

  local season_num = parse_number(season) or 1
  local episode_num = parse_number(episode, {allow_zero = true})
  local season_hint = "s" .. tostring(season_num)

  return {
    title = title,
    display_title = title,
    normalized_title = normalized,
    season = season_num,
    season_hint = season_hint,
    episode_no = episode_num,
    source = source,
    raw_title = raw_title,
    alias_key = normalized .. "|" .. season_hint,
  }
end

local function parse_text_candidate(raw_title, source, decode)
  raw_title = trim(raw_title)
  if not raw_title or raw_title == "" then
    return nil
  end

  local thin_space = string.char(0xE2, 0x80, 0x89)
  local text = raw_title:gsub(thin_space, " ")
  if decode then
    text = url_decode(text) or text
  end

  local pipe_title = text:match("^(.-)%s*|%s*.-%s*$")
  if pipe_title and pipe_title ~= "" then
    text = pipe_title
  end
  text = strip_stream_title_suffix(text) or text

  local format_title = format_filename(text)
  if format_title then
    local title, season, episode = parse_formatted_title(format_title)
    return build_title_info(title, season or parse_season_hint(text), episode, source, raw_title)
  end

  local parsed = utils.extract_info_from_filename(text)
  local title = parsed and parsed.title or text
  local season = parse_season_hint(text)
  local episode = parsed and parsed.episode or nil
  return build_title_info(title, season, episode, source, raw_title)
end

local function parse_option_title_candidate(raw_title, source)
  raw_title = trim(raw_title)
  if not raw_title or raw_title == "" then
    return nil
  end
  if raw_title:find("${", 1, true) then
    return nil
  end

  local text = raw_title
  local wrapped = text:match("^%s*《(.-)》")
    or text:match("^%s*【(.-)】")
    or text:match("^%s*%[(.-)%]")
  if wrapped and wrapped ~= "" then
    return build_title_info(wrapped, parse_season_hint(text), nil, source, raw_title)
  end

  local title = text:match("^(.-)%s*第%s*%d+%s*[话話集集].*$")
  if title and title ~= "" then
    return build_title_info(title, parse_season_hint(text), nil, source, raw_title)
  end

  return parse_text_candidate(raw_title, source, true)
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
    local path = mp.get_property("path")
    if path and utils.is_protocol(path) then
      local info = M.get_current_title_info()
      title = info and info.title or nil
    else
      title = select(1, parse_title())
    end
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

function M.normalize_title(title)
  return normalize_title(title)
end

function M.get_current_title_info()
  if not mp or not mp.get_property then
    return nil
  end

  local path = mp.get_property("path")
  local candidates = {}
  local function add_candidate(value, source, decode, parser)
    if value and value ~= "" then
      candidates[#candidates + 1] = { value = value, source = source, decode = decode, parser = parser }
    end
  end

  local is_network = path and utils.is_protocol(path)
  if is_network then
    add_candidate(mp.get_property("metadata/by-key/series"), "metadata-series", true)
    add_candidate(mp.get_property("metadata/by-key/ytdl_playlist_title"), "metadata-ytdl-playlist-title", true)
    add_candidate(mp.get_property("metadata/by-key/album"), "metadata-album", true)
    add_candidate(mp.get_property("options/title"), "options-title", true, parse_option_title_candidate)
  end

  add_candidate(mp.get_property("media-title"), "media-title", true)

  if mp.get_property_native then
    local playlist_pos = mp.get_property_number("playlist-pos")
    local playlist = mp.get_property_native("playlist")
    local item = playlist and playlist_pos and playlist[playlist_pos + 1] or nil
    add_candidate(item and item.title, "playlist-title", false)
  end

  add_candidate(mp.get_property("filename/no-ext"), "filename", false)

  if path and path ~= "" then
    if is_network then
      add_candidate(url_tail_decode(path), "url", false)
    else
      local filename = path:match("([^/\\]+)$") or path
      filename = filename:match("^(.+)%.[^%.]+$") or filename
      add_candidate(filename, "path", false)
    end
  end

  local title_info = nil
  local episode_info = nil
  for _, candidate in ipairs(candidates) do
    local parser = candidate.parser or parse_text_candidate
    local info = parser(candidate.value, candidate.source, candidate.decode)
    if info and info.normalized_title then
      if not title_info then
        title_info = info
        if title_info.episode_no then
          return title_info
        end
      end
      if info.episode_no and not episode_info then
        episode_info = info
      end
    end
  end

  if title_info and not title_info.episode_no and episode_info and episode_info.episode_no then
    local season = title_info.season
    if (not season or season == 1) and episode_info.season and episode_info.season > 1 then
      season = episode_info.season
    end
    return build_title_info(
      title_info.title,
      season,
      episode_info.episode_no,
      title_info.source,
      title_info.raw_title
    )
  end

  return title_info
end

return M

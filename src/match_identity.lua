local title_guess = require "src.title_guess"
local utils = require "src.utils"
local sha256 = require "src.sha256"
local storage_gate = require "src.core.storage_gate"

local M = {}

local GENERIC_DIRECTORIES = {
  anime = true, animation = true, animations = true, bangumi = true,
  download = true, downloads = true, video = true, videos = true,
  tv = true, media = true, temp = true, tmp = true,
  ["动漫"] = true, ["动画"] = true, ["番剧"] = true, ["下载"] = true,
}

local function normalize_path(path)
  path = path:gsub("\\", "/"):gsub("/+$", "")
  if mp.get_property_native("platform") == "windows" then
    path = path:lower()
  end
  return path
end

local function split_path(path)
  return path:match("^(.*)/([^/]+)$")
end

local function parse_directory(path, storage_root)
  local parent, name = split_path(path)
  if not name or (storage_root and normalize_path(path) == normalize_path(storage_root)) then
    return {}
  end
  local info = title_guess.parse_local_name(name, true)
  -- 季度目录向上一层取番剧名；不穿过配置的动画存储根目录。
  if info.season ~= nil and not info.title and parent and parent ~= "" then
    local series = parse_directory(parent, storage_root)
    info.title, info.normalized_title = series.title, series.normalized_title
    info.conflict = info.conflict or series.conflict
      or (series.season ~= nil and series.season ~= info.season)
  end
  if GENERIC_DIRECTORIES[info.normalized_title] then
    info.title, info.normalized_title = nil, nil
  end
  -- 特别篇的编号体系不能与本篇共享。
  local lower = name:lower()
  if lower:match("^specials?$") or lower:match("^sps?$")
    or lower:match("^ovas?$") or lower:match("^oads?$") then
    info.conflict = true
  end
  return info
end

local function resolve_identity(filename, directory)
  local conflict = filename.conflict or directory.conflict
    or (filename.season ~= nil and directory.season ~= nil and filename.season ~= directory.season)
  -- 不同语言的目录别名可能不相等，保守地只保留当前文件的匹配。
  if filename.normalized_title and directory.normalized_title
    and filename.normalized_title ~= directory.normalized_title then
    conflict = true
  end
  return {
    title = filename.title or directory.title,
    normalized_title = filename.normalized_title or directory.normalized_title,
    title_source = filename.title and "filename" or (directory.title and "directory" or nil),
    season = filename.season or directory.season,
    episode_no = filename.episode_no,
    conflict = conflict == true,
  }
end

local function apply_cache_policy(identity, path, directory)
  if not identity.normalized_title or identity.conflict
    or (identity.season ~= nil and identity.season < 1) then
    identity.scope = "file"
    identity.cache_key = "file:" .. sha256(path)
  elseif identity.season ~= nil then
    identity.scope = "series"
    identity.cache_key = identity.normalized_title .. "|s" .. tostring(identity.season)
  elseif directory then
    identity.scope = "directory"
    identity.cache_key = "directory:" .. sha256(directory) .. "|" .. identity.normalized_title
  else
    identity.scope = "file"
    identity.cache_key = "file:" .. sha256(path)
  end
  return identity
end

function M.for_local_path(path, storage_root)
  local directory, filename = split_path(path:gsub("\\", "/"))
  if not filename then
    return {}
  end
  local stem = filename:match("^(.+)%.[^%.]+$") or filename
  local identity = resolve_identity(
    title_guess.parse_local_name(stem, false),
    parse_directory(directory, storage_root)
  )
  return apply_cache_policy(identity, normalize_path(path), normalize_path(directory))
end

-- 自动匹配、手动绑定与刷新共用此入口，避免各处自行推导缓存键。
function M.get_current()
  local path = mp.get_property("path")
  if not path or path == "" then
    return {}
  end
  if utils.is_protocol(path) then
    -- 流媒体继续使用原有标题解析；网络完整文件不从 URL 目录猜番剧名。
    local info = title_guess.get_current_title_info() or {}
    local normalized = utils.normalize_search_title(info.title)
    if normalized and normalized:match("^%d+$") then normalized = nil end
    return apply_cache_policy({
      title = info.title, normalized_title = normalized,
      season = info.season_explicit and info.season or nil,
      episode_no = info.episode_no, title_source = info.source,
    }, path)
  end
  path = mp.command_native({"normalize-path", path})
  local storage = storage_gate.resolve_storage(path)
  return M.for_local_path(path, storage and storage.matched_storage)
end

function M.is_cache_key(key)
  return type(key) == "string" and (key:match("^.+|s%d+$") ~= nil
    or key:match("^directory:%x+|.+$") ~= nil or key:match("^file:%x+$") ~= nil)
end

return M

local mp_utils = require "mp.utils"
local paths = require "src.paths"
local utils = require "src.utils"

local M = {}

local DB_PATH = mp_utils.join_path(paths.DATA_PATH, "data.json")
local METADATA_PATH = mp_utils.join_path(paths.DATA_PATH, "metadata")

-- 确保metadata目录存在
local function ensure_metadata_dir()
  local info = mp_utils.file_info(METADATA_PATH)
  if not info or not info.is_dir then
    paths.ensure_dir(METADATA_PATH)
  end
end

ensure_metadata_dir()

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  return path:gsub("\\", "/")
end

local function is_cache_key(value)
  return type(value) == "string" and value:match("^.+|s%d+$") ~= nil
end

-- 缓存按“搜索标题清洗结果 + 季数”隔离，例如 example|s2。
function M.make_cache_key(title_info)
  if type(title_info) ~= "table" then
    return nil
  end

  local normalized_title = utils.normalize_search_title(title_info.title)
  if not normalized_title then
    return nil
  end

  local season = tonumber(title_info.season)
  if not season and title_info.season_hint then
    season = tonumber(tostring(title_info.season_hint):lower():match("^s0*(%d+)$"))
  end
  season = math.floor(season or 1)
  if season < 1 then
    season = 1
  end

  return normalized_title .. "|s" .. tostring(season)
end

local function split_path(path)
  if not path or path == "" then
    return nil, nil
  end
  local normalized = normalize_path(path)
  local dir = normalized:match("^(.+)/[^/]+$")
  local filename = normalized:match("([^/]+)$")
  return dir, filename
end

local function resolve_folder_and_filename(path_or_dir)
  if not path_or_dir or path_or_dir == "" then
    return nil, nil, nil
  end
  local normalized = normalize_path(path_or_dir)
  local info = mp_utils.file_info(path_or_dir)
  if info and info.is_dir then
    return normalized, nil, normalized
  end
  local dir, filename = split_path(normalized)
  if dir and filename then
    return dir, filename, normalized
  end
  return normalized, nil, normalized
end

local function ensure_folder(db, cache_key)
  if not is_cache_key(cache_key) then
    return nil, nil
  end
  local folder = db[cache_key]
  if type(folder) ~= "table" then
    folder = {}
    db[cache_key] = folder
  end
  if type(folder.entries) ~= "table" then
    folder.entries = {}
  end
  return folder, cache_key
end

local function ensure_entry(folder, filename, full_path)
  if not folder or not filename or filename == "" then
    return nil
  end
  local entry = folder.entries[filename]
  if type(entry) ~= "table" then
    entry = {}
    folder.entries[filename] = entry
  end
  if full_path and full_path ~= "" then
    entry.path = full_path
  end
  return entry
end

local function derive_unique_anime_id(entries)
  local anime_id = nil
  for _, entry in pairs(entries or {}) do
    if entry.dandanplay_id then
      local current = math.floor(entry.dandanplay_id / 10000)
      if not anime_id then
        anime_id = current
      elseif anime_id ~= current then
        return nil
      end
    end
  end
  return anime_id
end

local function update_folder_anime_id(folder)
  if not folder or folder.manual then
    return
  end
  local anime_id = derive_unique_anime_id(folder.entries)
  if anime_id then
    folder.anime_id = anime_id
  end
end

-- 加载数据库
local function load_db()
  local info = mp_utils.file_info(DB_PATH)
  if not info or not info.is_file then
    return {}
  end
  
  local file = io.open(DB_PATH, "r")
  if not file then
    return {}
  end
  
  local content = file:read("*all")
  file:close()
  
  local data = mp_utils.parse_json(content)
  return data or {}
end

-- 保存数据库
local function save_db(data)
  local file = io.open(DB_PATH, "w")
  if not file then
    mp.msg.error("无法打开数据库文件: " .. DB_PATH)
    return false
  end
  
  local json = mp_utils.format_json(data)
  if not json then
    -- 简单的JSON序列化
    json = "{}"
  end
  
  file:write(json)
  file:close()
  return true
end

-- 获取记录
function M.get(query)
  query = query or {}
  if not is_cache_key(query.cache_key) then
    return nil
  end

  local db = load_db()
  local folder = db[query.cache_key]
  if type(folder) ~= "table" then
    return nil
  end

  if query.path then
    local _, filename = split_path(query.path)
    if filename then
      local entry = folder and folder.entries and folder.entries[filename] or nil
      if entry then
        local full_path = query.path or entry.path
        local now = os.time()
        if folder then
          folder.last_seen = now
          save_db(db)
        end
        return {
          path = full_path,
          bgm_id = folder.bgm_id,
          dandanplay_id = entry.dandanplay_id,
          anime_id = folder.anime_id,
          manual = folder.manual == true,
        }
      end
    end
    return nil
  end

  for _, entry in pairs(folder.entries or {}) do
    local match = true
    if query.bgm_id and folder.bgm_id ~= query.bgm_id then
      match = false
    end
    if query.dandanplay_id and entry.dandanplay_id ~= query.dandanplay_id then
      match = false
    end
    if match then
      local full_path = entry.path
      local now = os.time()
      if folder then
        folder.last_seen = now
      end
      save_db(db)
      return {
        path = full_path,
        bgm_id = folder.bgm_id,
        dandanplay_id = entry.dandanplay_id,
        anime_id = folder.anime_id,
        manual = folder.manual == true,
      }
    end
  end

  return nil
end

-- 设置bgm_id
function M.set_bgm_id(path, id_, cache_key)
  local db = load_db()
  local _, filename = split_path(path)
  if not filename then
    return false
  end
  local folder = ensure_folder(db, cache_key)
  local entry = ensure_entry(folder, filename, path)
  if not entry then
    return false
  end
  folder.bgm_id = id_
  folder.last_seen = os.time()
  save_db(db)
  return true
end

-- 设置dandanplay_id
function M.set_dandanplay_id(path, id_, cache_key)
  local db = load_db()
  local _, filename = split_path(path)
  if not filename then
    return false
  end
  local folder = ensure_folder(db, cache_key)
  local entry = ensure_entry(folder, filename, path)
  if not entry then
    return false
  end
  entry.dandanplay_id = id_
  folder.last_seen = os.time()
  update_folder_anime_id(folder)
  save_db(db)
  return true
end

-- 获取自动加载源
function M.get_autoload_source(cache_key, filename)
  if not is_cache_key(cache_key) then
    return nil
  end
  local db = load_db()
  local folder = db[cache_key]
  local anime_id = folder and folder.anime_id or nil
  if not anime_id and folder and folder.entries then
    anime_id = derive_unique_anime_id(folder.entries)
  end
  if not anime_id then
    return nil
  end

  local info = utils.extract_info_from_filename(filename)
  if not info.episode then
    return nil
  end
  
  return anime_id * 10000 + info.episode
end

function M.get_cache_info(cache_key)
  if not is_cache_key(cache_key) then
    return nil
  end
  local db = load_db()
  local folder = db[cache_key]
  if not folder then
    return nil
  end
  return {
    anime_id = folder.anime_id,
    bgm_id = folder.bgm_id,
    manual = folder.manual == true,
    entries = folder.entries,
  }
end

function M.set_manual_selection(path_or_dir, anime_id, cache_key)
  local db = load_db()
  local folder = ensure_folder(db, cache_key)
  if not folder then
    return false
  end
  folder.manual = true
  if anime_id then
    folder.anime_id = anime_id
  end
  folder.last_seen = os.time()
  save_db(db)
  return true
end

function M.set_manual_bgm_id(path_or_dir, bgm_id, cache_key)
  local id_ = tonumber(bgm_id)
  if not id_ then
    return false
  end
  local db = load_db()
  local _, filename, normalized_path = resolve_folder_and_filename(path_or_dir)
  local folder = ensure_folder(db, cache_key)
  if not folder then
    return false
  end

  folder.manual = true
  folder.bgm_id = id_
  folder.last_seen = os.time()

  if filename then
    ensure_entry(folder, filename, normalized_path)
  end

  save_db(db)
  return true
end

-- 获取剧集信息
function M.get_episode_info(episode_id)
  local anime_dir = tostring(math.floor(episode_id / 10000))
  local filename = tostring(episode_id) .. ".json"
  local info_path = mp_utils.join_path(mp_utils.join_path(METADATA_PATH, anime_dir), filename)

  local info = mp_utils.file_info(info_path)
  if not info or not info.is_file then
    return nil
  end
  
  local file = io.open(info_path, "r")
  if not file then
    return nil
  end
  
  local content = file:read("*all")
  file:close()
  
  return mp_utils.parse_json(content)
end

-- 设置剧集信息
function M.set_episode_info(episode_id, data)
  local dir_path = mp_utils.join_path(
    METADATA_PATH,
    tostring(math.floor(episode_id / 10000))
  )
  
  local info = mp_utils.file_info(dir_path)
  if not info or not info.is_dir then
    paths.ensure_dir(dir_path)
  end

  local info_path = mp_utils.join_path(dir_path, tostring(episode_id) .. ".json")
  local file = io.open(info_path, "w")
  if not file then
    mp.msg.error("无法写入剧集信息: " .. info_path)
    return false
  end
  
  local json = mp_utils.format_json(data)
  if not json then
    json = "{}"
  end
  
  file:write(json)
  file:close()
  return true
end


-- 获取路径
function M.get_path(episode_id, type_)
  local base_path = mp_utils.join_path(
    METADATA_PATH,
    tostring(math.floor(episode_id / 10000))
  )
  
  if type_ == "comment" then
    return mp_utils.join_path(base_path, tostring(episode_id) .. "-comment.json")
  elseif type_ == "ass" then
    return mp_utils.join_path(base_path, tostring(episode_id) .. "-comment.ass")
  elseif type_ == "info" then
    return mp_utils.join_path(base_path, tostring(math.floor(episode_id / 10000)) .. "-info.json")
  elseif type_ == "metadata" then
    return mp_utils.join_path(base_path, tostring(episode_id) .. ".json")
  elseif type_ == "episodes" then
    return mp_utils.join_path(base_path, "episodes.json")
  else
    error("Unknown type: " .. tostring(type_))
  end
end


local function remove_metadata_dirs(anime_id)
  if type(anime_id) ~= "number" then
    return 0
  end
  local dir_path = mp_utils.join_path(METADATA_PATH, tostring(anime_id))
  local info = mp_utils.file_info(dir_path)
  if info and info.is_dir then
    return paths.remove_dir(dir_path) and 1 or 0
  end
  return 0
end

function M.prune(opts)
  opts = opts or {}
  local max_age_days = opts.max_age_days or 180
  local remove_missing = opts.remove_missing == true
  local max_folders = opts.max_folders or opts.max_records or 0
  local db = load_db()
  local now = os.time()
  local removed = 0
  local dirty = false
  local max_age = max_age_days > 0 and (max_age_days * 24 * 3600) or nil
  local candidates = {}
  local removed_anime_ids = {}

  local function remove_record(cache_key, folder)
    for _ in pairs(folder.entries or {}) do
      removed = removed + 1
    end
    if type(folder.anime_id) == "number" then
      removed_anime_ids[folder.anime_id] = true
    end
    db[cache_key] = nil
    dirty = true
  end

  for cache_key, folder in pairs(db) do
    local entries = folder.entries
    if type(entries) ~= "table" then
      entries = {}
      folder.entries = entries
    end

    local folder_last_seen = folder.last_seen or 0
    if max_age and folder_last_seen == 0 then
      folder.last_seen = now
      folder_last_seen = now
      dirty = true
    end
    local is_expired = max_age and (now - folder_last_seen) > max_age
    local is_missing = false
    if remove_missing and next(entries) then
      is_missing = true
      for _, entry in pairs(entries) do
        local full_path = entry.path
        if not full_path then
          is_missing = false
          break
        end
        local info = mp_utils.file_info(full_path)
        if info and info.is_file then
          is_missing = false
          break
        end
      end
    end

    if is_expired or is_missing then
      remove_record(cache_key, folder)
    else
      if max_folders > 0 then
        candidates[#candidates + 1] = {key = cache_key, last_seen = folder_last_seen}
      end
      if not next(entries) and not folder.manual and not folder.anime_id then
        db[cache_key] = nil
        dirty = true
      end
    end
  end

  if max_folders > 0 and #candidates > max_folders then
    table.sort(candidates, function(a, b)
      return a.last_seen < b.last_seen
    end)
    local excess = #candidates - max_folders
    for i = 1, excess do
      local item = candidates[i]
      local folder = db[item.key]
      if folder then
        remove_record(item.key, folder)
      end
    end
  end

  if next(removed_anime_ids) then
    local referenced_anime_ids = {}
    for _, folder in pairs(db) do
      if type(folder) == "table" and type(folder.anime_id) == "number" then
        referenced_anime_ids[folder.anime_id] = true
      end
    end
    for anime_id in pairs(removed_anime_ids) do
      if not referenced_anime_ids[anime_id] then
        remove_metadata_dirs(anime_id)
      end
    end
  end

  if removed > 0 or dirty then
    save_db(db)
  end

  return removed
end

return M

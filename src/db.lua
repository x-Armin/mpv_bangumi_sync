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
    os.execute('mkdir "' .. METADATA_PATH .. '"')
  end
end

ensure_metadata_dir()

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  return path:gsub("\\", "/")
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

local function ensure_folder(db, dir_path)
  local key = normalize_path(dir_path)
  if not key or key == "" then
    return nil, nil
  end
  local folder = db[key]
  if type(folder) ~= "table" then
    folder = {}
    db[key] = folder
  end
  if type(folder.entries) ~= "table" then
    folder.entries = {}
  end
  return folder, key
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
  local db = load_db()
  if query.path then
    local dir, filename = split_path(query.path)
    if dir and filename then
      local folder = db[normalize_path(dir)]
      local entry = folder and folder.entries and folder.entries[filename] or nil
      if entry then
        local full_path = entry.path or query.path
        local now = os.time()
        if folder then
          folder.last_seen = now
          save_db(db)
        end
        return {
          path = full_path,
          bgm_id = entry.bgm_id,
          dandanplay_id = entry.dandanplay_id,
          anime_id = folder.anime_id,
          manual = folder.manual == true,
        }
      end
    end
  end

  for dir, folder in pairs(db) do
    for filename, entry in pairs(folder.entries or {}) do
      local match = true
      if query.path and entry.path ~= query.path then
        match = false
      end
      if query.bgm_id and entry.bgm_id ~= query.bgm_id then
        match = false
      end
      if query.dandanplay_id and entry.dandanplay_id ~= query.dandanplay_id then
        match = false
      end
      if match then
        local full_path = entry.path or (dir .. "/" .. filename)
        local now = os.time()
        if folder then
          folder.last_seen = now
          save_db(db)
        end
        return {
          path = full_path,
          bgm_id = entry.bgm_id,
          dandanplay_id = entry.dandanplay_id,
          anime_id = folder.anime_id,
          manual = folder.manual == true,
        }
      end
    end
  end

  return nil
end

-- 设置bgm_id
function M.set_bgm_id(path, id_)
  local db = load_db()
  local dir, filename = split_path(path)
  if not dir or not filename then
    return false
  end
  local folder = ensure_folder(db, dir)
  local entry = ensure_entry(folder, filename, path)
  if not entry then
    return false
  end
  entry.bgm_id = id_
  folder.last_seen = os.time()
  save_db(db)
  return true
end

-- 设置dandanplay_id
function M.set_dandanplay_id(path, id_)
  local db = load_db()
  local dir, filename = split_path(path)
  if not dir or not filename then
    return false
  end
  local folder = ensure_folder(db, dir)
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
function M.get_autoload_source(dir_, filename)
  local db = load_db()
  local folder = db[normalize_path(dir_)]
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

function M.get_folder_info(dir_path)
  local db = load_db()
  local folder = db[normalize_path(dir_path)]
  if not folder then
    return nil
  end
  return {
    anime_id = folder.anime_id,
    manual = folder.manual == true,
    entries = folder.entries,
  }
end

function M.set_manual_selection(path_or_dir, anime_id)
  local db = load_db()
  local dir, _ = split_path(path_or_dir)
  if not dir then
    dir = path_or_dir
  end
  local folder = ensure_folder(db, dir)
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
    os.execute('mkdir "' .. dir_path .. '"')
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

-- 检查文件是否过期
function M.is_outdated(file_path, max_age)
  max_age = max_age or (3600 * 4) -- 默认4小时
  
  local info = mp_utils.file_info(file_path)
  if not info or not info.is_file then
    return true
  end
  
  local current_time = os.time()
  local file_time = info.mtime
  if current_time - file_time > max_age then
    return true
  end
  
  return false
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

-- 获取或更新
function M.get_or_update(episode_id, type_, update_cb, max_age)
  max_age = max_age or (3600 * 4)
  
  local path = M.get_path(episode_id, type_)
  
  if not M.is_outdated(path, max_age) then
    local file = io.open(path, "r")
    if file then
      local content = file:read("*all")
      file:close()
      return mp_utils.parse_json(content)
    end
  end
  
  local data = update_cb()
  
  local dir_path = path:match("^(.+)/[^/]+$")
  if dir_path then
    local info = mp_utils.file_info(dir_path)
    if not info or not info.is_dir then
      os.execute('mkdir "' .. dir_path .. '"')
    end
  end
  
  local file = io.open(path, "w")
  if file then
    local json = mp_utils.format_json(data)
    if not json then
      json = "{}"
    end
    file:write(json)
    file:close()
  end
  
  return data
end

local function remove_metadata_dirs(anime_id)
  if type(anime_id) ~= "number" then
    return 0
  end
  local platform = (mp and mp.get_property_native and mp.get_property_native("platform")) or ""
  local dir_path = mp_utils.join_path(METADATA_PATH, tostring(anime_id))
  local info = mp_utils.file_info(dir_path)
  if info and info.is_dir then
    if platform == "windows" then
      local path = dir_path:gsub("/", "\\")
      os.execute('rmdir /s /q "' .. path .. '"')
    else
      os.execute('rm -rf "' .. dir_path .. '"')
    end
    return 1
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

  for dir, folder in pairs(db) do
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
      for filename, entry in pairs(entries) do
        local full_path = entry.path or (dir .. "/" .. filename)
        local info = mp_utils.file_info(full_path)
        if info and info.is_file then
          is_missing = false
          break
        end
      end
    end

    if is_expired or is_missing then
      for _ in pairs(entries) do
        removed = removed + 1
      end
      remove_metadata_dirs(folder.anime_id)
      db[dir] = nil
    else
      if max_folders > 0 then
        candidates[#candidates + 1] = {dir = dir, last_seen = folder_last_seen}
      end
      if not next(entries) and not folder.manual and not folder.anime_id then
        db[dir] = nil
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
      local folder = db[item.dir]
      if folder then
        local entries = folder.entries or {}
        for _ in pairs(entries) do
          removed = removed + 1
        end
        remove_metadata_dirs(folder.anime_id)
        db[item.dir] = nil
      end
    end
  end

  if removed > 0 or dirty then
    save_db(db)
  end

  return removed
end

return M

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
  
  for path, record in pairs(db) do
    local match = true
    if query.path and record.path ~= query.path then
      match = false
    end
    if query.bgm_id and record.bgm_id ~= query.bgm_id then
      match = false
    end
    if query.dandanplay_id and record.dandanplay_id ~= query.dandanplay_id then
      match = false
    end
    
    if match then
      return {
        path = record.path or path,
        bgm_id = record.bgm_id,
        dandanplay_id = record.dandanplay_id,
      }
    end
  end
  
  return nil
end

-- 设置bgm_id
function M.set_bgm_id(path, id_)
  local db = load_db()
  if not db[path] then
    db[path] = {}
  end
  db[path].path = path
  db[path].bgm_id = id_
  save_db(db)
end

-- 设置dandanplay_id
function M.set_dandanplay_id(path, id_)
  local db = load_db()
  if not db[path] then
    db[path] = {}
  end
  db[path].path = path
  db[path].dandanplay_id = id_
  save_db(db)
end

-- 获取自动加载源
function M.get_autoload_source(dir_, filename)
  local db = load_db()
  local anime_ids = {}
  
  for path, record in pairs(db) do
    if path:find(dir_, 1, true) and record.dandanplay_id then
      local anime_id = math.floor(record.dandanplay_id / 10000)
      anime_ids[anime_id] = true
    end
  end
  
  local anime_id_list = {}
  for id, _ in pairs(anime_ids) do
    table.insert(anime_id_list, id)
  end
  
  if #anime_id_list ~= 1 then
    return nil
  end
  
  local anime_id = anime_id_list[1]
  local info = utils.extract_info_from_filename(filename)
  if not info.episode then
    return nil
  end
  
  return anime_id * 10000 + info.episode
end

-- 获取剧集信息
function M.get_episode_info(episode_id)
  local info_path = mp_utils.join_path(
    METADATA_PATH,
    tostring(math.floor(episode_id / 10000)),
    tostring(episode_id) .. ".json"
  )
  
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

return M

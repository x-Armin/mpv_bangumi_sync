local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local paths = require "src.paths"
local bangumi_api = require "src.bangumi_api"
local dandanplay_api = require "src.dandanplay_api"
local video_info = require "src.video_info"
local config = require "src.config"
local json_store = require "src.core.json_store"
local storage_gate = require "src.core.storage_gate"

local M = {}

local INFO_CACHE_MAX_AGE = 3600 * 24
local EPISODES_CACHE_MAX_AGE = 3600 * 4

local function get_current_file_path()
  local file_path = mp.get_property("path")
  if not file_path then
    return nil
  end
  return mp.command_native({"normalize-path", file_path})
end

local function ensure_parent_dir(path)
  if not path or path == "" then
    return
  end
  local normalized = path:gsub("\\", "/")
  local dir_path = normalized:match("^(.+)/[^/]+$")
  if dir_path then
    paths.ensure_dir(dir_path)
  end
end

local function read_json_file(path)
  local info = mp_utils.file_info(path)
  if not info or not info.is_file then
    return nil
  end
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    return nil
  end
  return mp_utils.parse_json(content)
end

local function write_json_file(path, data)
  if not data then
    return false
  end
  local json = mp_utils.format_json(data)
  if not json then
    return false
  end
  ensure_parent_dir(path)
  local file = io.open(path, "w")
  if not file then
    return false
  end
  file:write(json)
  file:close()
  return true
end

local function is_cache_fresh(path, max_age)
  local info = mp_utils.file_info(path)
  if not info or not info.is_file then
    return false
  end
  local age = os.time() - info.mtime
  return age <= max_age
end

local function read_cached_json(path, max_age, validate)
  if not is_cache_fresh(path, max_age) then
    return nil
  end
  local data = read_json_file(path)
  if not data then
    return nil
  end
  if validate and not validate(data) then
    return nil
  end
  return data
end

read_json_file = function(path)
  return json_store.read(path)
end

write_json_file = function(path, data)
  return json_store.write(path, data, {atomic = true})
end

is_cache_fresh = function(path, max_age)
  return json_store.is_fresh(path, max_age)
end

read_cached_json = function(path, max_age, validate)
  return json_store.read(path, {max_age = max_age, validate = validate})
end

local function build_episode_info_from_anime(anime_info, episode_id)
  if not anime_info or not anime_info.episodes then
    mp.msg.error("anime_info or episodes missing")
    return nil
  end

  for _, episode in ipairs(anime_info.episodes) do
    if tostring(episode.episodeId) == tostring(episode_id) then
      return {
        episodeId = episode.episodeId,
        animeId = anime_info.animeId,
        animeTitle = anime_info.animeTitle,
        episodeTitle = episode.episodeTitle,
        type = anime_info.type,
        typeDescription = anime_info.typeDescription,
        shift = 0.0,
      }
    end
  end
  mp.msg.error("Episode ID not found in anime_info: " .. tostring(episode_id))
  return nil
end

local function get_anime_info_cached(episode_id, anime_id, opts)
  local force_refresh = opts and opts.force_refresh
  local info_path = db.get_path(episode_id, "info")
  if not force_refresh then
    local cached = read_cached_json(info_path, INFO_CACHE_MAX_AGE, function(data)
      return data and data.episodes
    end)
    if cached then
      mp.msg.verbose(
        string.format(
          "sync_context: anime_info 缓存命中 episode_id=%s anime_id=%s path=%s",
          tostring(episode_id),
          tostring(anime_id),
          info_path
        )
      )
      return cached
    end
  end

  mp.msg.verbose(
    string.format(
      "sync_context: anime_info 缓存未命中 episode_id=%s anime_id=%s refresh=%s",
      tostring(episode_id),
      tostring(anime_id),
      tostring(force_refresh == true)
    )
  )
  local fresh = dandanplay_api.get_anime_info(anime_id)
  if fresh and fresh.episodes then
    write_json_file(info_path, fresh)
    return fresh
  end
  mp.msg.error(
    string.format(
      "Failed to get anime info from API episode_id=%s anime_id=%s",
      tostring(episode_id),
      tostring(anime_id)
    )
  )
  return nil
end

local function get_user_episodes_cached(episode_id, bgm_id, opts)
  if not bgm_id then
    return nil
  end
  local force_refresh = opts and opts.force_refresh
  local episodes_path = db.get_path(episode_id, "episodes")
  if not force_refresh then
    local cached = read_cached_json(episodes_path, EPISODES_CACHE_MAX_AGE, function(data)
      return data and data.data
    end)
    if cached then
      mp.msg.verbose(
        string.format(
          "sync_context: episodes 缓存命中 episode_id=%s bgm_id=%s path=%s",
          tostring(episode_id),
          tostring(bgm_id),
          episodes_path
        )
      )
      return cached
    end
  end

  mp.msg.verbose(
    string.format(
      "sync_context: episodes 缓存未命中 episode_id=%s bgm_id=%s refresh=%s",
      tostring(episode_id),
      tostring(bgm_id),
      tostring(force_refresh == true)
    )
  )
  local episodes = bangumi_api.get_user_episodes(bgm_id)
  if not episodes or not episodes.body or not episodes.body.data then
    return nil
  end
  write_json_file(episodes_path, episodes.body)
  return episodes.body
end

-- 检查视频是否在存储路径中
local function is_in_storage_path(file_path)
  local storages = config.config.storages or {}
  for _, storage in ipairs(storages) do
    if file_path:find(storage, 1, true) == 1 then
      return true
    end
  end
  return false
end

is_in_storage_path = function(file_path)
  return storage_gate.is_in_storage_path(file_path)
end

-- 构造episode match
local function construct_episode_match(episode_id, opts)
  local anime_id = math.floor(episode_id / 10000)
  local anime_info = get_anime_info_cached(episode_id, anime_id, opts)
  local episode_info = build_episode_info_from_anime(anime_info, episode_id)
  if not episode_info then
    mp.msg.error("无法获取anime信息以构造episode match")
    return nil
  end
  return episode_info
end

-- 获取匹配信息
local function get_match_info(video_path)
  local info = video_info.get_info(video_path)
  if not info then
    mp.msg.verbose("match: video_info not available")
    mp.msg.error("无法获取视频信息: " .. video_path)
    return {}
  end
  
  local matches = dandanplay_api.match(info)
  if not matches or #matches == 0 then
    mp.msg.verbose("match: no candidates from dandanplay")
    mp.msg.error("未找到匹配: " .. info.filename)
    return {}
  end
  
  mp.msg.verbose("match: dandanplay candidates=" .. tostring(#matches))
  return matches
end

local function format_match_results(matches)
  local match_list = {}
  for _, match in ipairs(matches or {}) do
    table.insert(match_list, {
      episodeId = match.episodeId,
      animeTitle = match.animeTitle,
      episodeTitle = match.episodeTitle,
    })
  end
  return match_list
end

local function sync_context_execute(opts)
  opts = opts or {}
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  local force_episode_id = type(opts) == "table" and opts.episode_id or nil
  local source = type(opts) == "table" and opts.source or nil
  local ensure_episodes = type(opts) ~= "table" or opts.ensure_episodes ~= false
  local refresh = force_refresh or source == "manual"

  mp.msg.verbose(
    string.format(
      "sync_context: 开始 source=%s force_refresh=%s ensure_episodes=%s force_episode_id=%s",
      tostring(source),
      tostring(force_refresh == true),
      tostring(ensure_episodes),
      tostring(force_episode_id)
    )
  )
  local file_path = get_current_file_path()
  local file_info = file_path and mp_utils.file_info(file_path) or nil
  if not file_info or not file_info.is_file then
    mp.msg.verbose("sync_context: 文件路径无效或不是文件")
    mp.msg.error("视频路径无效或不是文件")
    return {status = "error", error = "VideoPathError", reason = "InvalidPath"}
  end

  mp.msg.verbose("sync_context: 已获取文件路径")
  if not is_in_storage_path(file_path) then
    mp.msg.info("sync_context: 文件不在配置的存储路径内")
    return {
      status = "error",
      error = "VideoPathError",
      reason = "NotInStorage",
    }
  end

  local db_record = db.get({path = file_path})
  local episode_id = force_episode_id or (db_record and db_record.dandanplay_id)
  local episode_info = nil
  local anime_info = nil
  mp.msg.verbose(
    string.format(
      "sync_context: db 记录 dandanplay_id=%s bgm_id=%s",
      tostring(db_record and db_record.dandanplay_id),
      tostring(db_record and db_record.bgm_id)
    )
  )

  if force_episode_id then
    mp.msg.verbose("sync_context: 强制 episode_id=" .. tostring(force_episode_id))
    db.set_dandanplay_id(file_path, force_episode_id)
  end

  if not episode_id then
    local dir_path = file_path:match("^(.+)/[^/]+$") or file_path:match("^(.+)\\[^\\]+$") or ""
    local filename = file_path:match("([^/\\]+)$") or file_path
    local autoload_id = db.get_autoload_source(dir_path, filename)
    if autoload_id then
      mp.msg.verbose("sync_context: 自动加载 episode_id=" .. tostring(autoload_id))
      episode_id = autoload_id
    end
  end

  if episode_id then
    mp.msg.verbose("sync_context: 当前 episode_id=" .. tostring(episode_id))
    episode_info = db.get_episode_info(episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: episode_info 缓存命中")
    end
  end

  if not episode_id then
    local matches = get_match_info(file_path)
    mp.msg.verbose("sync_context: 匹配候选数=" .. tostring(#matches))
    if #matches > 1 then
      local dir_path = file_path:match("^(.+)/[^/]+$") or file_path:match("^(.+)\\[^\\]+$") or ""
      local folder_info = dir_path ~= "" and db.get_folder_info(dir_path) or nil
      if folder_info and folder_info.manual and folder_info.anime_id then
        for _, match in ipairs(matches) do
          local match_anime_id = math.floor(match.episodeId / 10000)
          if match_anime_id == folder_info.anime_id then
            mp.msg.verbose(
              "sync_context: 通过手动 anime_id 自动选择匹配=" .. tostring(folder_info.anime_id)
            )
            episode_info = match
            episode_id = match.episodeId
            db.set_dandanplay_id(file_path, episode_id)
            db.set_episode_info(episode_id, episode_info)
            break
          end
        end
        if not episode_id then
          mp.msg.verbose("sync_context: 候选中未找到手动 anime_id")
        end
      end

      if not episode_id then
        local filename = file_path:match("([^/\\]+)$") or file_path
        local info = utils.extract_info_from_filename(filename)
        mp.msg.verbose("sync_context: 匹配结果需要手动选择")
        return {
          status = "select",
          info = info,
          matches = format_match_results(matches),
        }
      end
    end

    if not episode_id then
      episode_info = matches[1]
      if episode_info then
        mp.msg.verbose("sync_context: 选中匹配 episode_id=" .. tostring(episode_info.episodeId))
        episode_id = episode_info.episodeId
        db.set_dandanplay_id(file_path, episode_id)
        db.set_episode_info(episode_id, episode_info)
      end
    end
  end

  if not episode_id then
    mp.msg.error("Match failed: " .. file_path)
    mp.msg.verbose("sync_context: 匹配后仍未获得 episode_id")
    return {status = "error", error = "MatchNotFound", video = file_path}
  end

  if source == "manual" then
    local anime_id = math.floor(episode_id / 10000)
    db.set_manual_selection(file_path, anime_id)
    mp.msg.verbose("sync_context: 已保存手动 anime_id=" .. tostring(anime_id))
  end

  if not episode_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = refresh})
    episode_info = build_episode_info_from_anime(anime_info, episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: 已从 anime_info 构建 episode_info")
      db.set_episode_info(episode_id, episode_info)
    end
  end

  if not episode_info then
    mp.msg.error("Episode info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: 查询 anime_info 后仍缺少 episode_info")
    return {status = "error", error = "EpisodeInfoError", episode_id = episode_id}
  end

  db.set_dandanplay_id(file_path, episode_id)

  if not anime_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = refresh})
  end

  if not anime_info or not anime_info.bangumiUrl then
    mp.msg.error("Anime info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: anime_info 缺失或无 bangumiUrl")
    return {status = "error", error = "AnimeInfoError", episode_id = episode_id}
  end

  local bgm_id = tonumber(anime_info.bangumiUrl:match("/(%d+)$"))
  mp.msg.verbose("sync_context: 解析 bgm_id=" .. tostring(bgm_id))
  if bgm_id then
    db.set_bgm_id(file_path, bgm_id)
  end

  local episodes = nil
  if ensure_episodes then
    episodes = get_user_episodes_cached(episode_id, bgm_id, {force_refresh = refresh})
    mp.msg.verbose("sync_context: episodes 已加载=" .. tostring(episodes ~= nil))
  end

  return {
    status = "ok",
    context = {
      file_path = file_path,
      episode_id = episode_id,
      episode_info = episode_info,
      anime_info = anime_info,
      bgm_id = bgm_id,
      bgm_url = bgm_id and ("https://bgm.tv/subject/" .. tostring(bgm_id)) or nil,
      episodes = episodes,
    },
  }
end

function M.sync_context(opts)
  return {
    execute = function()
      return sync_context_execute(opts)
    end,
    async = function(cb)
      cb = cb or {}
      cb.resp = cb.resp or function(_) end
      cb.err = cb.err or function(_) end
      local result = sync_context_execute(opts)
      if result and result.status ~= "error" then
        cb.resp(result)
      else
        cb.err(result)
      end
    end,
  }
end

-- 匹配视频（force_id可选）
function M.match(force_id)
  local opts = {
    episode_id = force_id,
    ensure_episodes = false,
    source = force_id and "manual" or "auto",
  }

  return {
    execute = function()
      local result = sync_context_execute(opts)
      if not result then
        return nil
      end
      if result.status == "select" then
        return {info = result.info, matches = result.matches}
      end
      if result.status == "ok" and result.context and result.context.episode_info then
        local episode_info = result.context.episode_info
        return {
          info = episode_info,
          desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
        }
      end
      return nil
    end,
    async = function(cb)
      cb = cb or {}
      cb.resp = cb.resp or function(_) end
      cb.err = cb.err or function() end
      local result = sync_context_execute(opts)
      if not result then
        cb.err()
        return
      end
      if result.status == "select" then
        cb.resp({info = result.info, matches = result.matches})
        return
      end
      if result.status == "ok" and result.context and result.context.episode_info then
        local episode_info = result.context.episode_info
        cb.resp({
          info = episode_info,
          desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
        })
        return
      end
      cb.err()
    end,
  }
end


-- 打开URL

M.construct_episode_match = construct_episode_match
M.get_anime_info_cached = get_anime_info_cached
M.get_user_episodes_cached = get_user_episodes_cached

return M

local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local paths = require "src.paths"
local bangumi_api = require "src.bangumi_api"
local dandanplay_api = require "src.dandanplay_api"
local video_info = require "src.video_info"
local config = require "src.config"

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
          "sync_context: anime_info cache hit episode_id=%s anime_id=%s path=%s",
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
      "sync_context: anime_info cache miss episode_id=%s anime_id=%s refresh=%s",
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
          "sync_context: episodes cache hit episode_id=%s bgm_id=%s path=%s",
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
      "sync_context: episodes cache miss episode_id=%s bgm_id=%s refresh=%s",
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
      "sync_context: start source=%s force_refresh=%s ensure_episodes=%s force_episode_id=%s",
      tostring(source),
      tostring(force_refresh == true),
      tostring(ensure_episodes),
      tostring(force_episode_id)
    )
  )
  local file_path = get_current_file_path()
  local file_info = file_path and mp_utils.file_info(file_path) or nil
  if not file_info or not file_info.is_file then
    mp.msg.verbose("sync_context: file_path invalid or not a file")
    mp.msg.error("Invalid video path: " .. tostring(file_path))
    return {status = "error", error = "VideoPathError", video = file_path}
  end

  mp.msg.verbose("sync_context: file_path=" .. tostring(file_path))
  if not is_in_storage_path(file_path) then
    mp.msg.verbose("sync_context: file_path not in configured storages")
    mp.msg.verbose("Video not in storage path: " .. file_path)
    return {
      status = "error",
      error = "VideoPathError",
      video = file_path,
      storage = config.config.storages or {},
    }
  end

  local db_record = db.get({path = file_path})
  local episode_id = force_episode_id or (db_record and db_record.dandanplay_id)
  local episode_info = nil
  local anime_info = nil
  mp.msg.verbose(
    string.format(
      "sync_context: db_record dandanplay_id=%s bgm_id=%s",
      tostring(db_record and db_record.dandanplay_id),
      tostring(db_record and db_record.bgm_id)
    )
  )

  if force_episode_id then
    mp.msg.verbose("sync_context: force_episode_id=" .. tostring(force_episode_id))
    db.set_dandanplay_id(file_path, force_episode_id)
  end

  if not episode_id then
    local dir_path = file_path:match("^(.+)/[^/]+$") or file_path:match("^(.+)\\[^\\]+$") or ""
    local filename = file_path:match("([^/\\]+)$") or file_path
    local autoload_id = db.get_autoload_source(dir_path, filename)
    if autoload_id then
      mp.msg.verbose("sync_context: autoload_id=" .. tostring(autoload_id))
      episode_id = autoload_id
    end
  end

  if episode_id then
    mp.msg.verbose("sync_context: episode_id=" .. tostring(episode_id))
    episode_info = db.get_episode_info(episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: episode_info cache hit")
    end
  end

  if not episode_id then
    local matches = get_match_info(file_path)
    mp.msg.verbose("sync_context: match candidates=" .. tostring(#matches))
    if #matches > 1 then
      local filename = file_path:match("([^/\\]+)$") or file_path
      local info = utils.extract_info_from_filename(filename)
      mp.msg.verbose("sync_context: match requires selection")
      return {
        status = "select",
        info = info,
        matches = format_match_results(matches),
      }
    end

    episode_info = matches[1]
    if episode_info then
      mp.msg.verbose("sync_context: match picked episode_id=" .. tostring(episode_info.episodeId))
      episode_id = episode_info.episodeId
      db.set_dandanplay_id(file_path, episode_id)
      db.set_episode_info(episode_id, episode_info)
    end
  end

  if not episode_id then
    mp.msg.error("Match failed: " .. file_path)
    mp.msg.verbose("sync_context: no episode_id after match attempts")
    return {status = "error", error = "MatchNotFound", video = file_path}
  end

  if not episode_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = refresh})
    episode_info = build_episode_info_from_anime(anime_info, episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: episode_info built from anime_info")
      db.set_episode_info(episode_id, episode_info)
    end
  end

  if not episode_info then
    mp.msg.error("Episode info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: episode_info missing after anime_info lookup")
    return {status = "error", error = "EpisodeInfoError", episode_id = episode_id}
  end

  db.set_dandanplay_id(file_path, episode_id)

  if not anime_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = refresh})
  end

  if not anime_info or not anime_info.bangumiUrl then
    mp.msg.error("Anime info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: anime_info missing or no bangumiUrl")
    return {status = "error", error = "AnimeInfoError", episode_id = episode_id}
  end

  local bgm_id = tonumber(anime_info.bangumiUrl:match("/(%d+)$"))
  mp.msg.verbose("sync_context: bgm_id=" .. tostring(bgm_id))
  if bgm_id then
    db.set_bgm_id(file_path, bgm_id)
  end

  local episodes = nil
  if ensure_episodes then
    episodes = get_user_episodes_cached(episode_id, bgm_id, {force_refresh = refresh})
    mp.msg.verbose("sync_context: episodes loaded=" .. tostring(episodes ~= nil))
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

-- 更新元数据
function M.update_metadata(opts)
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  local source = type(opts) == "table" and opts.source or nil
  local result = sync_context_execute({
    force_refresh = force_refresh,
    ensure_episodes = false,
    source = source,
  })
  if not result or result.status ~= "ok" or not result.context then
    return utils.subprocess_err()
  end

  local bgm_id = result.context.bgm_id
  local bgm_url = result.context.bgm_url
  if not bgm_id or not bgm_url then
    return utils.subprocess_err()
  end

  return {
    execute = function()
      return {
        bgm_id = bgm_id,
        bgm_url = bgm_url,
      }
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({
          bgm_id = bgm_id,
          bgm_url = bgm_url,
        })
      end
    end,
  }
end

-- 打开URL
function M.open_url(url)
  local platform = mp.get_property_native("platform")
  local cmd
  if platform == "windows" then
    cmd = {"cmd", "/c", "start", "", url}
  elseif platform == "darwin" then
    cmd = {"open", url}
  else
    cmd = {"xdg-open", url}
  end
  
  return utils.subprocess_wrapper(cmd)
end

-- 更新Bangumi收藏
function M.update_bangumi_collection()
  if not AnimeInfo or not AnimeInfo.bgm_id then
    mp.msg.error("未匹配到Bangumi ID，更新条目失败")
    return utils.subprocess_err()
  end
  
  local subject_id = AnimeInfo.bgm_id
  local res = bangumi_api.get_user_collection(subject_id)
  
  if not res or not res.body then
    mp.msg.error("获取用户收藏失败")
    return utils.subprocess_err()
  end
  
  local status = res.body.type
  local update_message = nil
  mp.msg.error("获取用户收藏状态:" .. res.status_code)
  if not status then
    -- 404，未收藏
    if res.status_code == 404 then
      bangumi_api.update_user_collection(subject_id, 3)
      update_message = "条目状态更新：未看 -> 在看"
    end
  else
    -- 已收藏，检查状态
    local status_map = {"想看", nil, nil, "搁置", "抛弃"}
    local update_from = status_map[status]
    if update_from then
      bangumi_api.update_user_collection(subject_id, 3)
      update_message = "条目状态更新：" .. update_from .. " -> 在看"
    end
  end
  
  return {
    execute = function()
      return {update_message = update_message}
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({update_message = update_message})
      end
    end,
  }
end

-- 获取剧集列表
function M.fetch_episodes(opts)
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  if not AnimeInfo or not AnimeInfo.bgm_id then
    mp.msg.error("未匹配到Bangumi ID，更新剧集失败")
    return utils.subprocess_err()
  end
  local file_path = get_current_file_path()
  local db_record = file_path and db.get({path = file_path}) or nil

  if not db_record or not db_record.bgm_id or not db_record.dandanplay_id then
    mp.msg.error("无法获取Bangumi ID和Dandanplay ID")
    return utils.subprocess_err()
  end

  local episodes = get_user_episodes_cached(
    db_record.dandanplay_id,
    db_record.bgm_id,
    {force_refresh = force_refresh}
  )
  if not episodes then
    mp.msg.error("获取剧集列表失败")
    return utils.subprocess_err()
  end
  
  return {
    execute = function()
      return {success = true}
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({success = true})
      end
    end,
  }
end

-- 更新剧集状态
function M.update_episode()
  if not AnimeInfo or not AnimeInfo.bgm_id then
    mp.msg.error("未匹配到Bangumi ID，更新剧集失败")
    return utils.subprocess_err()
  end
  
  local file_path = mp.get_property("path")
  file_path = mp.command_native({"normalize-path", file_path})
  local db_record = db.get({path = file_path})
  
  if not db_record or not db_record.bgm_id or not db_record.dandanplay_id then
    mp.msg.error("无法获取Bangumi ID和Dandanplay ID")
    return utils.subprocess_err()
  end
  
  local episode_id = db_record.dandanplay_id
  local ep = episode_id % 10000
  
  local episodes_path = db.get_path(episode_id, "episodes")
  local file = io.open(episodes_path, "r")
  if not file then
    mp.msg.error("剧集文件不存在: " .. episodes_path)
    return utils.subprocess_err()
  end
  
  local content = file:read("*all")
  file:close()
  local episodes_data = mp_utils.parse_json(content)
  
  if not episodes_data or not episodes_data.data then
    mp.msg.error("无法解析剧集文件")
    return utils.subprocess_err()
  end
  
  local episodes = episodes_data.data
  local bgm_episode_id = nil
  local episode = nil
  
  if ep > 1000 then
    -- 特殊集，通过标题匹配
    local episode_info = construct_episode_match(episode_id)
    if not episode_info then
      mp.msg.error("无法匹配剧集信息")
      return utils.subprocess_err()
    end
    
    local title = episode_info.episodeTitle
    local max_conf = 0
    local max_idx = 1
    
    for i, ep_info in ipairs(episodes) do
      local conf1 = utils.fuzzy_match_title(title, ep_info.episode.name or "")
      local conf2 = utils.fuzzy_match_title(title, ep_info.episode.name_cn or "")
      local conf = math.max(conf1, conf2)
      if conf > max_conf then
        max_conf = conf
        max_idx = i
      end
    end
    
    if max_conf < 0.8 then
      mp.msg.error("无法匹配剧集标题，相似度: " .. max_conf)
      return utils.subprocess_err()
    end
    
    episode = episodes[max_idx]
    bgm_episode_id = episode.episode.id
  else
    -- 普通集，通过集数匹配
    for _, ep_info in ipairs(episodes) do
      if ep_info.episode.ep == ep then
        episode = ep_info
        bgm_episode_id = episode.episode.id
        break
      end
    end
  end
  
  if not bgm_episode_id then
    mp.msg.error("无法找到对应的剧集")
    return utils.subprocess_err()
  end
  
  -- 检查是否已标记为看过
  local prev_status = bangumi_api.get_episode_status(bgm_episode_id)
  if prev_status and prev_status.body and prev_status.body.type == 2 then
    return {
      execute = function()
        return {progress = ep, total = #episodes, skipped = true}
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({progress = ep, total = #episodes, skipped = true})
        end
      end,
    }
  end
  
  -- 更新剧集状态
  local res = bangumi_api.update_episode_status(bgm_episode_id, 2)
  if not res or res.status_code >= 400 then
    mp.msg.error("更新剧集状态失败")
    return utils.subprocess_err()
  end
  
  return {
    execute = function()
      return {progress = ep, total = #episodes}
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({progress = ep, total = #episodes})
      end
    end,
  }
end

-- 搜索番剧
function M.dandanplay_search(keyword)
  return {
    execute = function()
      local results = dandanplay_api.search_anime(keyword)
      local formatted = {}
      for _, result in ipairs(results) do
        table.insert(formatted, {
          id = result.animeId,
          title = result.animeTitle,
          type = result.type,
        })
      end
      return formatted
    end,
    async = function(cb)
      if cb and cb.resp then
        local results = dandanplay_api.search_anime(keyword)
        local formatted = {}
        for _, result in ipairs(results) do
          table.insert(formatted, {
            id = result.animeId,
            title = result.animeTitle,
            type = result.type,
          })
        end
        cb.resp(formatted)
      end
    end,
  }
end

-- 获取剧集列表
function M.get_dandanplay_episodes(anime_id)
  local anchor_id = anime_id * 10000 + 1
  local anime_info = get_anime_info_cached(anchor_id, anime_id, {force_refresh = false})
  
  if not anime_info or not anime_info.episodes then
    return {
      execute = function()
        return {}
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({})
        end
      end,
    }
  end
  
  local episodes = {}
  for _, episode in ipairs(anime_info.episodes) do
    table.insert(episodes, {
      id = episode.episodeId,
      title = episode.episodeTitle,
    })
  end
  
  return {
    execute = function()
      return episodes
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp(episodes)
      end
    end,
  }
end

return M

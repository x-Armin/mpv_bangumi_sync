local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local dandanplay_api = require "src.dandanplay_api"
local video_info = require "src.video_info"
local config = require "src.config"

local M = {}

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
local function construct_episode_match(episode_id)
  local anime_id = math.floor(episode_id / 10000)
  
  local anime_info = db.get_or_update(episode_id, "info", function()
    return dandanplay_api.get_anime_info(anime_id)
  end)
  
  if not anime_info or not anime_info.episodes then
    mp.msg.error("无法获取anime信息以构造episode match")
    return nil
  end
  
  for _, episode in ipairs(anime_info.episodes) do
    if episode.episodeId == episode_id then
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
  
  return nil
end

-- 获取匹配信息
local function get_match_info(video_path)
  local info = video_info.get_info(video_path)
  if not info then
    mp.msg.error("无法获取视频信息: " .. video_path)
    return {}
  end
  
  local matches = dandanplay_api.match(info)
  if not matches or #matches == 0 then
    mp.msg.error("未找到匹配: " .. info.filename)
    return {}
  end
  
  return matches
end

-- 匹配视频（force_id可选）
function M.match(force_id)
  local file_path = mp.get_property("path")
  file_path = mp.command_native({"normalize-path", file_path})
  local file_info = mp_utils.file_info(file_path)
  
  if not file_info or not file_info.is_file then
    mp.msg.error("文件不存在或不是有效的文件: " .. file_path)
    return utils.subprocess_err()
  end
  
  -- 检查是否在存储路径中
  if not is_in_storage_path(file_path) then
    mp.msg.verbose("视频不在存储路径中，跳过: " .. file_path)
    return {
      execute = function()
        return {
          error = "VideoPathError",
          video = file_path,
          storage = config.config.storages or {},
        }
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({
            error = "VideoPathError",
            video = file_path,
            storage = config.config.storages or {},
          })
        end
      end,
    }
  end
  
  local db_record = db.get({path = file_path})
  local episode_info = nil
  
  if force_id then
    -- 强制使用指定的episode ID
    episode_id = force_id
    episode_info = db.get_episode_info(episode_id)
    if not episode_info then
      episode_info = construct_episode_match(episode_id)
    end
    if episode_info then
      db.set_dandanplay_id(file_path, episode_info.episodeId)
      db.set_episode_info(episode_info.episodeId, episode_info)
    end
  elseif db_record and db_record.dandanplay_id then
    -- 使用数据库中的dandanplay_id
    episode_id = db_record.dandanplay_id
    episode_info = db.get_episode_info(episode_id)
    if not episode_info then
      episode_info = construct_episode_match(episode_id)
      if not episode_info then
        episode_info = get_match_info(file_path)[1]
      end
      if episode_info then
        db.set_dandanplay_id(file_path, episode_info.episodeId)
        db.set_episode_info(episode_id, episode_info)
      end
    end
  else

    -- 尝试自动加载
    local dir_path = file_path:match("^(.+)/[^/]+$") or file_path:match("^(.+)\\[^\\]+$") or ""
    local filename = file_path:match("([^/\\]+)$") or file_path
    local autoload_id = db.get_autoload_source(dir_path, filename)
    if autoload_id then

      episode_id = autoload_id
      episode_info = db.get_episode_info(episode_id)
      if not episode_info then
        episode_info = construct_episode_match(episode_id)
        if not episode_info then
          episode_info = get_match_info(file_path)[1]
        end
        if episode_info then
          db.set_episode_info(episode_id, episode_info)
        end
      end
      if episode_info then
        db.set_dandanplay_id(file_path, episode_info.episodeId)
      end
    else
      -- 匹配视频
      local matches = get_match_info(file_path)
      if #matches > 1 then
        -- 多个匹配，返回让用户选择
        return {
          execute = function()
            local info = utils.extract_info_from_filename(file_path:match("([^/]+)$"))
            local match_list = {}
            for _, match in ipairs(matches) do
              table.insert(match_list, {
                episodeId = match.episodeId,
                animeTitle = match.animeTitle,
                episodeTitle = match.episodeTitle,
              })
            end
            return {
              info = info,
              matches = match_list,
            }
          end,
          async = function(cb)
            if cb and cb.resp then
              local info = utils.extract_info_from_filename(file_path:match("([^/]+)$"))
              local match_list = {}
              for _, match in ipairs(matches) do
                table.insert(match_list, {
                  episodeId = match.episodeId,
                  animeTitle = match.animeTitle,
                  episodeTitle = match.episodeTitle,
                })
              end
              cb.resp({
                info = info,
                matches = match_list,
              })
            end
          end,
        }
      end
      episode_info = matches[1]
      if episode_info then
        db.set_dandanplay_id(file_path, episode_info.episodeId)
        db.set_episode_info(episode_info.episodeId, episode_info)
      end
    end
  end
  
  if not episode_info then
    mp.msg.error("无法匹配视频: " .. file_path)
    return utils.subprocess_err()
  end
  
  return {
    execute = function()
      return {
        info = episode_info,
        desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
      }
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({
          info = episode_info,
          desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
        })
      end
    end,
  }
end

-- 更新元数据
function M.update_metadata()
  local file_path = mp.get_property("path")
  file_path = mp.command_native({"normalize-path", file_path})
  local file_info = mp_utils.file_info(file_path)
  
  if not file_info or not file_info.is_file then
    mp.msg.error("文件不存在或不是有效的文件: " .. file_path)
    return utils.subprocess_err()
  end
  
  local db_record = db.get({path = file_path})
  if not db_record or not db_record.dandanplay_id then
    -- 先匹配
    M.match().execute()
    db_record = db.get({path = file_path})
  end
  
  if not db_record or not db_record.dandanplay_id then
    mp.msg.error("无法获取dandanplay_id")
    return utils.subprocess_err()
  end
  
  local episode_id = db_record.dandanplay_id
  local anime_id = math.floor(episode_id / 10000)
  
  local anime_info = db.get_or_update(episode_id, "info", function()
    return dandanplay_api.get_anime_info(anime_id)
  end, 3600 * 24) -- 24小时过期
  
  if not anime_info or not anime_info.bangumiUrl then
    mp.msg.error("无法获取anime信息")
    return utils.subprocess_err()
  end
  
  local bgm_id = tonumber(anime_info.bangumiUrl:match("/(%d+)$"))
  if bgm_id then
    db.set_bgm_id(file_path, bgm_id)
  end
  
  return {
    execute = function()
      return {
        bgm_id = bgm_id,
        bgm_url = "https://bgm.tv/subject/" .. tostring(bgm_id),
      }
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({
          bgm_id = bgm_id,
          bgm_url = "https://bgm.tv/subject/" .. tostring(bgm_id),
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
function M.fetch_episodes()
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
  
  local episodes_path = db.get_path(db_record.dandanplay_id, "episodes")
  
  if not db.is_outdated(episodes_path) then
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
  
  local episodes = bangumi_api.get_user_episodes(db_record.bgm_id)
  if not episodes or not episodes.body or not episodes.body.data then
    mp.msg.error("获取剧集列表失败")
    return utils.subprocess_err()
  end
  
  -- 保存剧集列表
  local file = io.open(episodes_path, "w")
  if file then
    file:write(mp_utils.format_json(episodes.body) or "{}")
    file:close()
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
  local anime_info = db.get_or_update(anime_id * 10000 + 1, "info", function()
    return dandanplay_api.get_anime_info(anime_id)
  end)
  
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

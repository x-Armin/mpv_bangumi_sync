local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local sync_context = require "src.services.sync_context"

local M = {}

local pending_episode_ids = {}

local function queue_pending_episode(subject_id, episode_id)
  if not subject_id or not episode_id then
    return
  end
  local set = pending_episode_ids[subject_id]
  if not set then
    set = {}
    pending_episode_ids[subject_id] = set
  end
  set[episode_id] = true
end

function M.flush_pending()
  local results = {}
  for subject_id, set in pairs(pending_episode_ids) do
    local ids = {}
    for episode_id in pairs(set) do
      ids[#ids + 1] = episode_id
    end
    if #ids > 0 then
      table.sort(ids)
      local res = bangumi_api.update_episodes_status(subject_id, ids, 2)
      if not res or not res.status_code or res.status_code == 0 or res.status_code >= 400 then
        mp.msg.error("Batch update episode status failed:", subject_id)
      else
        results[#results + 1] = {subject_id = subject_id, count = #ids}
        pending_episode_ids[subject_id] = nil
      end
    end
  end
  return results
end

local function get_current_file_path()
  local file_path = mp.get_property("path")
  if not file_path then
    return nil
  end
  return mp.command_native({"normalize-path", file_path})
end


local function get_user_episodes_cached(episode_id, bgm_id, opts)
  if sync_context and sync_context.get_user_episodes_cached then
    return sync_context.get_user_episodes_cached(episode_id, bgm_id, opts)
  end
  return nil
end

local function construct_episode_match(episode_id, opts)
  if sync_context and sync_context.construct_episode_match then
    return sync_context.construct_episode_match(episode_id, opts)
  end
  return nil
end

function M.update_bangumi_collection(anime_info)
  local info = anime_info or AnimeInfo
  if not info or not info.bgm_id then
    mp.msg.error("未匹配到Bangumi ID，更新条目失败")
    return utils.subprocess_err()
  end
  
  local subject_id = info.bgm_id
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
function M.fetch_episodes(opts, anime_info)
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  local info = anime_info or AnimeInfo
  if not info or not info.bgm_id then
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
function M.update_episode(opts)
  opts = opts or {}
  local info = opts.anime_info or AnimeInfo
  local defer = opts.defer == true
  if not info or not info.bgm_id then
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
  local function mark_episode_watched(ep_info)
    if not ep_info then
      return false
    end
    local changed = false
    if ep_info.type ~= 2 then
      ep_info.type = 2
      changed = true
    end
    return changed
  end
  local function persist_episodes_if_needed(changed)
    if not changed then
      return
    end
    local out = io.open(episodes_path, "w")
    if out then
      out:write(mp_utils.format_json(episodes_data) or "{}")
      out:close()
    end
  end
  
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

  if defer then
    local changed = mark_episode_watched(episode)
    persist_episodes_if_needed(changed)
    queue_pending_episode(info.bgm_id, bgm_episode_id)
    return {
      execute = function()
        return {progress = ep, total = #episodes, deferred = true, episodes_data = episodes_data}
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({progress = ep, total = #episodes, deferred = true, episodes_data = episodes_data})
        end
      end,
    }
  end
  
  -- 检查是否已标记为看过
  local prev_status = bangumi_api.get_episode_status(bgm_episode_id)
  if prev_status and prev_status.body and prev_status.body.type == 2 then
    local changed = mark_episode_watched(episode)
    persist_episodes_if_needed(changed)
    return {
      execute = function()
        return {progress = ep, total = #episodes, skipped = true, episodes_data = episodes_data}
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({progress = ep, total = #episodes, skipped = true, episodes_data = episodes_data})
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
  -- 本地标记为已看并持久化（补偿性更新），使返回的 episodes_data 包含最新状态
  local changed = mark_episode_watched(episode)
  persist_episodes_if_needed(changed)

  return {
    execute = function()
      return {progress = ep, total = #episodes, episodes_data = episodes_data}
    end,
    async = function(cb)
      if cb and cb.resp then
        cb.resp({progress = ep, total = #episodes, episodes_data = episodes_data})
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

-- 搜索番剧

return M

local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local sync_context = require "src.services.sync_context"
local config = require "src.config"
local episode_matcher = require "src.episode_matcher"
local storage_gate = require "src.core.storage_gate"
local episode_status = require "src.services.episode_status"

local M = {}

local pending_episode_ids = {}

local function is_auto_mark_enabled()
  local opts = config and config.options or {}
  return opts.enable_auto_mark ~= false
end

local function normalize_batch_threshold(value, default_value)
  local threshold = tonumber(value)
  if threshold == nil then
    threshold = default_value or 0
  end
  if threshold < 0 then
    threshold = 0
  end
  return math.floor(threshold)
end

local function resolve_storage_config(opts)
  opts = opts or {}
  if opts.storage and opts.storage.key then
    return opts.storage
  end
  local file_path = mp.get_property("path")
  if file_path then
    file_path = mp.command_native({"normalize-path", file_path})
  end
  return storage_gate.resolve_storage(file_path) or {
    key = "storage1",
    batch_sync_threshold = 1,
  }
end

local function get_storage_threshold(storage_config)
  return normalize_batch_threshold(storage_config and storage_config.batch_sync_threshold, 1)
end

local function get_pending_subject_set(storage_key, subject_id)
  local group = pending_episode_ids[storage_key]
  if not group then
    group = {}
    pending_episode_ids[storage_key] = group
  end
  local set = group[subject_id]
  if not set then
    set = {}
    group[subject_id] = set
  end
  return set
end

local function count_pending(set)
  local count = 0
  for _ in pairs(set or {}) do
    count = count + 1
  end
  return count
end

local function queue_pending_episode(storage_config, subject_id, episode_id)
  if not subject_id or not episode_id then
    return {queued = false, queued_count = 0, threshold = 0}
  end
  local storage_key = (storage_config and storage_config.key) or "storage1"
  local threshold = get_storage_threshold(storage_config)
  local set = get_pending_subject_set(storage_key, subject_id)
  set[episode_id] = true
  local count = count_pending(set)
  if threshold > 0 and count >= threshold then
    local results = M.flush_pending({storage_key = storage_key, subject_id = subject_id})
    local flushed = results and #results > 0
    return {
      queued = true,
      queued_count = count,
      threshold = threshold,
      flushed = flushed,
      flush_failed = not flushed,
      flush_results = results,
    }
  end
  return {
    queued = true,
    queued_count = count,
    threshold = threshold,
    deferred = true,
  }
end

function M.flush_pending(opts)
  opts = opts or {}
  if not is_auto_mark_enabled() and opts.force ~= true then
    return {}
  end

  local results = {}
  for storage_key, subjects in pairs(pending_episode_ids) do
    if not opts.storage_key or opts.storage_key == storage_key then
      for subject_id, set in pairs(subjects) do
        if not opts.subject_id or tonumber(opts.subject_id) == tonumber(subject_id) then
          local ids = {}
          for episode_id in pairs(set) do
            ids[#ids + 1] = episode_id
          end
          if #ids > 0 then
            table.sort(ids)
            local res = bangumi_api.update_episodes_status(subject_id, ids, episode_status.EPISODE.WATCHED, opts)
            local detached_ok = res and res.detached == true
            if not detached_ok and (not res or not res.status_code or res.status_code == 0 or res.status_code >= 400) then
              mp.msg.error("Batch update episode status failed:", storage_key, subject_id)
            else
              results[#results + 1] = {storage_key = storage_key, subject_id = subject_id, count = #ids}
              subjects[subject_id] = nil
            end
          end
        end
      end
      if not next(subjects) then
        pending_episode_ids[storage_key] = nil
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

local function extract_episode_no_from_filename(file_path)
  if file_path and file_path ~= "" then
    local filename = file_path:match("([^/\\]+)$") or file_path
    local parsed = utils.extract_info_from_filename(filename)
    if parsed and type(parsed.episode) == "number" then
      return parsed.episode
    end
  end
  return nil
end

local function resolve_episode_no(file_path, episode_id)
  local current_ep = CurrentEpisodeInfo and CurrentEpisodeInfo.episodeEp or nil
  if type(current_ep) == "number" and current_ep > 0 then
    return current_ep
  end

  local current_episode_id = CurrentEpisodeInfo and tonumber(CurrentEpisodeInfo.episodeId) or nil
  if current_episode_id then
    return current_episode_id % 10000
  end

  if episode_id then
    return tonumber(episode_id) % 10000
  end

  return extract_episode_no_from_filename(file_path)
end

local function resolve_runtime_episode_id(file_path, bgm_id, db_record)
  local manual_bgm_mode = db_record
    and db_record.manual == true
    and tonumber(db_record.bgm_id)
    and tonumber(bgm_id)
    and tonumber(db_record.bgm_id) == tonumber(bgm_id)
  if manual_bgm_mode then
    local ep = extract_episode_no_from_filename(file_path)
    if not ep then
      return nil, nil
    end
    return tonumber(bgm_id) * 10000 + ep, ep
  end

  local episode_id = db_record and db_record.dandanplay_id or nil
  if not episode_id and CurrentEpisodeInfo and CurrentEpisodeInfo.episodeId then
    episode_id = tonumber(CurrentEpisodeInfo.episodeId)
  end
  local ep = resolve_episode_no(file_path, episode_id)
  if not episode_id and bgm_id and ep then
    episode_id = tonumber(bgm_id) * 10000 + ep
  end
  return episode_id, ep
end


local function get_user_episodes_cached(episode_id, bgm_id, opts)
  if sync_context and sync_context.get_user_episodes_cached then
    return sync_context.get_user_episodes_cached(episode_id, bgm_id, opts)
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
  mp.msg.info("获取用户收藏状态:" .. res.status_code)
  if not status then
    -- 404，未收藏
    if res.status_code == 404 then
      bangumi_api.update_user_collection(subject_id, episode_status.COLLECTION.WATCHING)
      update_message = "条目状态更新：未看 -> 在看"
    end
  else
    -- 已收藏，检查状态
    local status_map = {
      [episode_status.COLLECTION.WISH] = "想看",
      [episode_status.COLLECTION.ON_HOLD] = "搁置",
      [episode_status.COLLECTION.DROPPED] = "抛弃",
    }
    local update_from = status_map[status]
    if update_from then
      bangumi_api.update_user_collection(subject_id, episode_status.COLLECTION.WATCHING)
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
  local runtime_episode_id = resolve_runtime_episode_id(file_path, info.bgm_id, db_record)

  if not runtime_episode_id then
    mp.msg.error("无法定位当前集，刷新剧集失败")
    return utils.subprocess_err()
  end

  local episodes = get_user_episodes_cached(
    runtime_episode_id,
    info.bgm_id,
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
  if not is_auto_mark_enabled() then
    return {
      execute = function()
        return {disabled = true, skipped = true}
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({disabled = true, skipped = true})
        end
      end,
    }
  end

  local info = opts.anime_info or AnimeInfo
  local storage_config = resolve_storage_config(opts)
  if not info or not info.bgm_id then
    mp.msg.error("未匹配到Bangumi ID，更新剧集失败")
    return utils.subprocess_err()
  end

  local collection_update_message = nil
  local collection_resp = M.update_bangumi_collection(info).execute()
  if collection_resp and collection_resp.update_message then
    collection_update_message = collection_resp.update_message
  elseif not collection_resp then
    mp.msg.warn("收藏状态检测失败，继续更新单集状态")
  end
  
  local file_path = mp.get_property("path")
  file_path = mp.command_native({"normalize-path", file_path})
  local db_record = db.get({path = file_path})
  local manual_bgm_mode = db_record
    and db_record.manual == true
    and tonumber(db_record.bgm_id)
    and tonumber(info.bgm_id)
    and tonumber(db_record.bgm_id) == tonumber(info.bgm_id)

  local episode_id, ep = resolve_runtime_episode_id(file_path, info.bgm_id, db_record)
  if not episode_id or not ep then
    mp.msg.error("无法定位当前集")
    return utils.subprocess_err()
  end

  local episodes_path = db.get_path(episode_id, "episodes")
  local file = io.open(episodes_path, "r")
  local episodes_data = nil
  if not file then
    episodes_data = get_user_episodes_cached(episode_id, info.bgm_id, {force_refresh = true})
    if not episodes_data then
      mp.msg.error("剧集文件不存在且拉取失败: " .. episodes_path)
      return utils.subprocess_err()
    end
  else
    local content = file:read("*all")
    file:close()
    episodes_data = mp_utils.parse_json(content)
  end
  
  if not episodes_data or not episodes_data.data then
    mp.msg.error("无法解析剧集文件")
    return utils.subprocess_err()
  end
  
  local episodes = episodes_data.data
  local bgm_episode_id = nil
  local episode = nil
  local match_result = nil
  local function mark_episode_watched(ep_info)
    if not ep_info then
      return false
    end
    local changed = false
    if ep_info.type ~= episode_status.EPISODE.WATCHED then
      ep_info.type = episode_status.EPISODE.WATCHED
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
  
  if not manual_bgm_mode then
    local direct_bgm_episode_id = CurrentEpisodeInfo and tonumber(CurrentEpisodeInfo.bgmEpisodeId) or nil
    if direct_bgm_episode_id then
      bgm_episode_id = direct_bgm_episode_id
      for _, ep_info in ipairs(episodes) do
        if ep_info.episode and tonumber(ep_info.episode.id) == bgm_episode_id then
          episode = ep_info
          break
        end
      end
    end
  end

  if not bgm_episode_id then
    match_result = episode_matcher.match_by_number(episodes, ep)
    local matched = match_result and match_result.target or nil
    if matched and matched.episode then
      episode = matched
      bgm_episode_id = matched.episode.id
    end
  end
  if manual_bgm_mode then
    mp.msg.verbose(
      string.format(
        "bangumi_service: manual_bgm 匹配 mode=%s reason=%s parsed_no=%s max_main_ep=%s",
        tostring(match_result and match_result.mode),
        tostring(match_result and match_result.reason),
        tostring(ep),
        tostring(match_result and match_result.stats and match_result.stats.max_main_ep)
      )
    )
    if match_result and match_result.reason == "sort_fallback_parsed_gt_max_ep" then
      mp.msg.verbose("bangumi_service: 检测到累计编号映射，已使用 sort 兜底")
    end
  end

  if not bgm_episode_id and not manual_bgm_mode then
    local title = CurrentEpisodeInfo and CurrentEpisodeInfo.episodeTitle or ""
    local max_conf = 0
    local max_idx = nil

    for i, ep_info in ipairs(episodes) do
      local ep_name = ep_info.episode and ep_info.episode.name or ""
      local ep_name_cn = ep_info.episode and ep_info.episode.name_cn or ""
      local conf = math.max(
        utils.fuzzy_match_title(title, ep_name),
        utils.fuzzy_match_title(title, ep_name_cn)
      )
      if conf > max_conf then
        max_conf = conf
        max_idx = i
      end
    end

    if max_idx and max_conf >= 0.8 then
      episode = episodes[max_idx]
      bgm_episode_id = episode and episode.episode and episode.episode.id or nil
    end
  end
  
  if not bgm_episode_id then
    if manual_bgm_mode then
      mp.msg.error(
        string.format(
          "无法找到对应的剧集: parsed_no=%s max_main_ep=%s mode=%s reason=%s",
          tostring(ep),
          tostring(match_result and match_result.stats and match_result.stats.max_main_ep),
          tostring(match_result and match_result.mode),
          tostring(match_result and match_result.reason)
        )
      )
    else
      mp.msg.error("无法找到对应的剧集，请手动匹配修正")
    end
    return utils.subprocess_err()
  end

  do
    local changed = mark_episode_watched(episode)
    persist_episodes_if_needed(changed)
    local queue_result = queue_pending_episode(storage_config, info.bgm_id, bgm_episode_id)
    return {
      execute = function()
        return {
          progress = ep,
          total = #episodes,
          deferred = queue_result.deferred == true,
          flushed = queue_result.flushed == true,
          flush_failed = queue_result.flush_failed == true,
          queued_count = queue_result.queued_count,
          batch_sync_threshold = queue_result.threshold,
          storage_key = storage_config and storage_config.key,
          episodes_data = episodes_data,
          collection_update_message = collection_update_message,
        }
      end,
      async = function(cb)
        if cb and cb.resp then
          cb.resp({
            progress = ep,
            total = #episodes,
            deferred = queue_result.deferred == true,
            flushed = queue_result.flushed == true,
            flush_failed = queue_result.flush_failed == true,
            queued_count = queue_result.queued_count,
            batch_sync_threshold = queue_result.threshold,
            storage_key = storage_config and storage_config.key,
            episodes_data = episodes_data,
            collection_update_message = collection_update_message,
          })
        end
      end,
    }
  end
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

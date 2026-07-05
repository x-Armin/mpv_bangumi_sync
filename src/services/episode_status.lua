local utils = require "src.utils"
local db = require "src.db"
local json_store = require "src.core.json_store"
local episode_matcher = require "src.episode_matcher"

local M = {}

function M.map_status(status)
  local status_map = {
    [0] = "未看",
    [1] = "想看",
    [2] = "已看",
    [3] = "搁置",
    [4] = "抛弃",
  }
  return status_map[status] or "未知"
end

local function collection_is_watched(collection)
  if not collection then
    return false
  end
  local status = collection.type
  if type(collection.status) == "table" then
    status = collection.status.id or collection.status.name or status
  end
  if tonumber(status) == 2 then
    return true
  end
  status = tostring(status or ""):lower()
  return status == "collect" or status == "watched" or status == "看过"
end

function M.compute(current_episode_info, episodes_data)
  if not current_episode_info or not current_episode_info.episodeId then
    return nil
  end

  if not episodes_data then
    local episodes_path = db.get_path(current_episode_info.episodeId, "episodes")
    episodes_data = json_store.read(episodes_path)
  end

  if not episodes_data or not episodes_data.data then
    return nil
  end

  local episodes = episodes_data.data
  local target = nil
  local match_mode = nil
  local direct_bgm_episode_id = tonumber(current_episode_info.bgmEpisodeId)
  local ep = current_episode_info.episodeEp
  local sort_no = tonumber(current_episode_info.episodeSort)
  local episode_id = tonumber(current_episode_info.episodeId)
  if type(ep) ~= "number" or ep <= 0 then
    if not episode_id then
      return nil
    end
    ep = episode_id % 10000
  end
  local total = #episodes
  local watched = 0

  for _, ep_info in ipairs(episodes) do
    if ep_info.type == 2 then
      watched = watched + 1
    end
  end

  if direct_bgm_episode_id then
    for _, ep_info in ipairs(episodes) do
      local bgm_ep_id = ep_info and ep_info.episode and tonumber(ep_info.episode.id) or nil
      if bgm_ep_id and bgm_ep_id == direct_bgm_episode_id then
        target = ep_info
        match_mode = "bgm_episode_id"
        break
      end
    end
  end

  if not target and type(sort_no) == "number" and sort_no > 0 then
    for _, ep_info in ipairs(episodes) do
      local current_sort = ep_info and ep_info.episode and tonumber(ep_info.episode.sort) or nil
      if current_sort and current_sort == sort_no then
        target = ep_info
        match_mode = "sort"
        break
      end
    end
  end

  if not target and type(ep) == "number" and ep > 0 then
    local match_result = episode_matcher.match_by_number(episodes, ep)
    if match_result and match_result.target then
      target = match_result.target
      match_mode = match_result.mode
    end
  end

  if not target then
    local title = current_episode_info.episodeTitle or ""
    local max_conf = 0
    for _, ep_info in ipairs(episodes) do
      local conf1 = utils.fuzzy_match_title(title, ep_info.episode and ep_info.episode.name or "")
      local conf2 = utils.fuzzy_match_title(title, ep_info.episode and ep_info.episode.name_cn or "")
      local conf = math.max(conf1, conf2)
      if conf > max_conf then
        max_conf = conf
        target = ep_info
        match_mode = "fuzzy"
      end
    end
    if max_conf < 0.8 then
      target = nil
      match_mode = nil
    end
  end

  local status = target and target.type or nil
  if target and collection_is_watched(episodes_data.collection) then
    status = 2
    watched = total
  end
  local updated_info = current_episode_info

  if target and target.episode then
    local bgm_ep_id = tonumber(target.episode.id)
    if bgm_ep_id then
      updated_info.bgmEpisodeId = bgm_ep_id
    end
    local ep_no = target.episode.ep
    if type(ep_no) == "number" and ep_no > 0 then
      updated_info.episodeEp = ep_no
    end
    local sort_val = tonumber(target.episode.sort)
    if sort_val and sort_val > 0 then
      updated_info.episodeSort = sort_val
    end
    if match_mode == "ep" or match_mode == "sort" then
      updated_info.episodeMatchMode = match_mode
    end
    local name_cn = target.episode.name_cn
    local name = target.episode.name
    local resolved_title = (name_cn and name_cn ~= "" and name_cn) or (name and name ~= "" and name) or nil
    if resolved_title then
      updated_info.episodeTitle = resolved_title
    end
  end

  return {
    status_value = status,
    progress = {watched = watched, total = total},
    episode_info = updated_info,
    episode_item = target,
    bgm_episode_id = target and target.episode and tonumber(target.episode.id) or nil,
    match_mode = match_mode,
  }
end

return M

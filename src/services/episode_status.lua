local utils = require "src.utils"
local db = require "src.db"
local json_store = require "src.core.json_store"

local M = {}

M.EPISODE = {
  UNWATCHED = 0,
  WATCHED = 2,
}

M.COLLECTION = {
  WISH = 1,
  WATCHING = 3,
  ON_HOLD = 4,
  DROPPED = 5,
}

local episode_status_aliases = {
  ["0"] = M.EPISODE.UNWATCHED,
  unwatched = M.EPISODE.UNWATCHED,
  not_watched = M.EPISODE.UNWATCHED,
  ["2"] = M.EPISODE.WATCHED,
  watched = M.EPISODE.WATCHED,
}

function M.normalize_episode_status(status)
  if type(status) == "number" then
    if status == M.EPISODE.UNWATCHED or status == M.EPISODE.WATCHED then
      return status
    end
    return nil
  end

  if type(status) == "string" then
    local key = status:lower():gsub("%s+", "_"):gsub("-", "_")
    return episode_status_aliases[key]
  end

  return nil
end

function M.map_status(status)
  local status_map = {
    [M.EPISODE.UNWATCHED] = "未看",
    [M.COLLECTION.WISH] = "想看",
    [M.EPISODE.WATCHED] = "已看",
    [M.COLLECTION.WATCHING] = "在看",
    [M.COLLECTION.ON_HOLD] = "搁置",
    [M.COLLECTION.DROPPED] = "抛弃",
  }
  return status_map[status] or "未知"
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
    if ep_info.type == M.EPISODE.WATCHED then
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

  if not target and type(ep) == "number" and ep > 0 then
    for _, ep_info in ipairs(episodes) do
      local current_ep = ep_info and ep_info.episode and tonumber(ep_info.episode.ep) or nil
      if current_ep and current_ep == ep then
        target = ep_info
        match_mode = "ep"
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

  if not target and ep > 1000 then
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
  elseif not target then
    for _, ep_info in ipairs(episodes) do
      if ep_info.episode and tonumber(ep_info.episode.ep) == ep then
        target = ep_info
        match_mode = "ep"
        break
      end
    end
  end

  local status = target and target.type or nil
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
  }
end

return M

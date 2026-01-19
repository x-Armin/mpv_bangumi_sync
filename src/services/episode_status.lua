local utils = require "src.utils"
local db = require "src.db"
local json_store = require "src.core.json_store"

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
  local ep = current_episode_info.episodeId % 10000
  local target = nil
  local total = #episodes
  local watched = 0

  for _, ep_info in ipairs(episodes) do
    if ep_info.type == 2 then
      watched = watched + 1
    end
  end

  if ep > 1000 then
    local title = current_episode_info.episodeTitle or ""
    local max_conf = 0
    for _, ep_info in ipairs(episodes) do
      local conf1 = utils.fuzzy_match_title(title, ep_info.episode and ep_info.episode.name or "")
      local conf2 = utils.fuzzy_match_title(title, ep_info.episode and ep_info.episode.name_cn or "")
      local conf = math.max(conf1, conf2)
      if conf > max_conf then
        max_conf = conf
        target = ep_info
      end
    end
  else
    for _, ep_info in ipairs(episodes) do
      if ep_info.episode and ep_info.episode.ep == ep then
        target = ep_info
        break
      end
    end
  end

  local status = target and target.type or nil
  local updated_info = current_episode_info

  if target and target.episode then
    local ep_no = target.episode.ep
    if type(ep_no) == "number" and ep_no > 0 then
      updated_info.episodeEp = ep_no
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

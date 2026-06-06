local bangumi_api = require "src.bangumi_api"

local M = {}

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil then
      value = tostring(value):match("^%s*(.-)%s*$")
      if value ~= "" then
        return value
      end
    end
  end
  return nil
end

function M.normalize_episode_items(body)
  if not body or type(body.data) ~= "table" then
    return nil
  end

  local normalized = {
    data = {},
    total = body.total,
    limit = body.limit,
    offset = body.offset,
  }

  for _, item in ipairs(body.data or {}) do
    if type(item) == "table" and type(item.episode) == "table" then
      normalized.data[#normalized.data + 1] = item
    elseif type(item) == "table" and item.id then
      normalized.data[#normalized.data + 1] = {
        episode = item,
        type = 0,
      }
    end
  end

  return #normalized.data > 0 and normalized or nil
end

function M.fetch_subject_episodes(bgm_id)
  local res = bangumi_api.get_subject_episodes(bgm_id)
  if not res or tonumber(res.status_code or 0) >= 400 then
    return nil
  end
  return M.normalize_episode_items(res.body)
end

function M.find_episode_by_bgm_id(episodes, bgm_episode_id)
  bgm_episode_id = tonumber(bgm_episode_id)
  if not episodes or not episodes.data or not bgm_episode_id then
    return nil
  end
  for _, ep_info in ipairs(episodes.data or {}) do
    local episode = ep_info and ep_info.episode or nil
    if episode and tonumber(episode.id) == bgm_episode_id then
      return ep_info, episode
    end
  end
  return nil
end

function M.episode_display_item(ep_info, index)
  local episode = ep_info and ep_info.episode or ep_info
  if type(episode) ~= "table" or not episode.id then
    return nil
  end

  local ep_no = tonumber(episode.ep)
  local sort_no = tonumber(episode.sort)
  local title = first_non_empty(
    episode.name_cn,
    episode.name,
    ep_no and ("Episode " .. tostring(ep_no)) or nil,
    sort_no and ("#" .. tostring(sort_no)) or nil
  ) or ("#" .. tostring(episode.id))
  local hint = nil
  if ep_no and sort_no then
    hint = "ep " .. tostring(ep_no) .. " / sort " .. tostring(sort_no)
  elseif ep_no then
    hint = "ep " .. tostring(ep_no)
  elseif sort_no then
    hint = "sort " .. tostring(sort_no)
  elseif index then
    hint = tostring(index)
  end

  return {
    id = episode.id,
    title = title,
    hint = hint,
    payload = ep_info,
  }
end

function M.display_items_from_episodes(episodes)
  local items = {}
  for i, ep_info in ipairs(episodes and episodes.data or {}) do
    local item = M.episode_display_item(ep_info, i)
    if item then
      items[#items + 1] = item
    end
  end
  return items
end

return M

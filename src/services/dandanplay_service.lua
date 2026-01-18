local dandanplay_api = require "src.dandanplay_api"
local sync_context = require "src.services.sync_context"

local function get_anime_info_cached(episode_id, anime_id, opts)
  if sync_context and sync_context.get_anime_info_cached then
    return sync_context.get_anime_info_cached(episode_id, anime_id, opts)
  end
  return nil
end


local M = {}

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

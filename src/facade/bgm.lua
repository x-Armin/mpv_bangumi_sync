local sync_context = require "src.services.sync_context"
local bangumi_service = require "src.services.bangumi_service"
local dandanplay_service = require "src.services.dandanplay_service"
local utils = require "src.utils"

local M = {}

M.sync_context = sync_context.sync_context
M.match = sync_context.match
M.update_bangumi_collection = bangumi_service.update_bangumi_collection
M.update_episode = bangumi_service.update_episode
M.fetch_episodes = bangumi_service.fetch_episodes
M.dandanplay_search = dandanplay_service.dandanplay_search
M.get_dandanplay_episodes = dandanplay_service.get_dandanplay_episodes

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

return M

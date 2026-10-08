local json_store = require "src.core.json_store"
local paths = require "src.paths"
local mp_utils = require "mp.utils"
local utils = require "src.utils"
local sha256 = require "src.sha256"

local M = {}
local BINDINGS_PATH = mp_utils.join_path(paths.DATA_PATH, "manual-episodes.json")

-- URL 保留查询参数参与哈希，避免同一播放入口的不同集共用绑定。
function M.current_key()
  local path = mp.get_property("path")
  if not path or path == "" then
    return nil
  end
  if not utils.is_protocol(path) then
    path = mp.command_native({"normalize-path", path}):gsub("\\", "/")
  end
  return sha256(path)
end

function M.get()
  local key = M.current_key()
  local data = key and json_store.read(BINDINGS_PATH) or nil
  return data and data[key] or nil
end

function M.save(subject_id, episode, title)
  local key = M.current_key()
  if not key or not tonumber(subject_id) or not episode or not tonumber(episode.id) then
    return false
  end
  local data = json_store.read(BINDINGS_PATH) or {}
  data[key] = {subject_id = tonumber(subject_id), episode = episode, title = title}
  return json_store.write(BINDINGS_PATH, data, {atomic = true})
end

function M.clear()
  local key = M.current_key()
  local data = key and json_store.read(BINDINGS_PATH) or nil
  if not data or not data[key] then
    return true
  end
  data[key] = nil
  return json_store.write(BINDINGS_PATH, data, {atomic = true})
end

-- 指定 ID 不存在时不回退到集数猜测，避免误标另一集。
function M.find_episode(episodes, binding)
  for _, item in ipairs(episodes or {}) do
    if item.episode and tonumber(item.episode.id) == tonumber(binding.episode.id) then
      return item, {mode = "manual", reason = "manual_episode_id"}
    end
  end
  return nil
end

function M.episode_label(episode)
  local types = {[0] = "本篇", [1] = "特别篇", [2] = "OP", [3] = "ED", [4] = "预告", [5] = "MAD", [6] = "其他"}
  local name = episode.name_cn
  if not name or name == "" then
    name = episode.name
  end
  if not name or name == "" then
    name = "未命名单集"
  end
  return string.format("[%s] %s  %s", types[tonumber(episode.type)] or "其他",
    tostring(episode.sort or episode.ep or "?"), name)
end

return M

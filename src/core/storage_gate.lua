local config = require "src.config"

local M = {}

function M.is_in_storage_path(file_path, storages)
  if not file_path or file_path == "" then
    return false
  end
  local list = storages or (config.config and config.config.storages) or {}
  for _, storage in ipairs(list) do
    if file_path:find(storage, 1, true) == 1 then
      return true
    end
  end
  return false
end

-- 判断是否为补番路径
function M.is_catchup_path(file_path)
  local list = (config.config and config.config.catchup_storages) or {}
  return M.is_in_storage_path(file_path, list)
end

-- 获取同步模式：new / catchup / nil
function M.get_sync_mode(file_path)
  if M.is_catchup_path(file_path) then
    return "catchup"
  end
  local list = (config.config and config.config.new_storages) or {}
  if M.is_in_storage_path(file_path, list) then
    return "new"
  end
  return nil
end

return M

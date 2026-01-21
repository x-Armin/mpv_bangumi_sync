local config = require "src.config"

local M = {}

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  path = path:gsub("\\", "/")
  if mp and mp.get_property_native and mp.get_property_native("platform") == "windows" then
    path = path:lower()
  end
  return path
end

function M.is_in_storage_path(file_path, storages)
  if not file_path or file_path == "" then
    return false
  end
  local list = storages or (config.config and config.config.storages) or {}
  local normalized_path = normalize_path(file_path)
  for _, storage in ipairs(list) do
    local normalized_storage = normalize_path(storage)
    if normalized_storage and normalized_storage ~= "" and normalized_path:find(normalized_storage, 1, true) == 1 then
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

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

function M.resolve_storage(file_path)
  if not file_path or file_path == "" then
    return nil
  end
  local normalized_path = normalize_path(file_path)
  local best = nil
  for _, group in ipairs((config.config and config.config.storage_groups) or {}) do
    for _, storage in ipairs(group.storages or {}) do
      local normalized_storage = normalize_path(storage)
      if normalized_storage
        and normalized_storage ~= ""
        and normalized_path:find(normalized_storage, 1, true) == 1 then
        local len = #normalized_storage
        if not best or len > best.match_length then
          best = {
            key = group.key,
            storages = group.storages,
            batch_sync_threshold = group.batch_sync_threshold,
            matched_storage = storage,
            match_length = len,
          }
        end
      end
    end
  end
  return best
end

return M

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

return M

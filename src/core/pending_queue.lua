local mp_utils = require "mp.utils"
local paths = require "src.paths"

local M = {}

local PENDING_FILE = mp_utils.join_path(paths.DATA_PATH, "pending_syncs.json")

function M.save(pending_table)
  if not pending_table or not next(pending_table) then
    M.clear()
    return true
  end

  local entries = {}
  for storage_key, subjects in pairs(pending_table) do
    for subject_id, set in pairs(subjects) do
      local ids = {}
      for episode_id in pairs(set) do
        ids[#ids + 1] = episode_id
      end
      if #ids > 0 then
        table.sort(ids)
        entries[#entries + 1] = {
          storage_key = storage_key,
          subject_id = subject_id,
          episode_ids = ids,
        }
      end
    end
  end

  if #entries == 0 then
    M.clear()
    return true
  end

  local file = io.open(PENDING_FILE, "w")
  if not file then
    mp.msg.error("pending_queue: 无法写入文件: " .. PENDING_FILE)
    return false
  end
  file:write(mp_utils.format_json({entries = entries}) or '{"entries":[]}')
  file:close()
  return true
end

function M.load()
  local info = mp_utils.file_info(PENDING_FILE)
  if not info or not info.is_file then
    return {}
  end
  local file = io.open(PENDING_FILE, "r")
  if not file then
    return {}
  end
  local content = file:read("*all")
  file:close()
  local data = mp_utils.parse_json(content)
  return data and data.entries or {}
end

function M.clear()
  os.remove(PENDING_FILE)
end

return M

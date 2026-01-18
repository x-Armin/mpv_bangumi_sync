local mp_utils = require "mp.utils"
local paths = require "src.paths"

local M = {}

local function ensure_parent_dir(path)
  if not path or path == "" then
    return
  end
  local normalized = path:gsub("\\", "/")
  local dir_path = normalized:match("^(.+)/[^/]+$")
  if dir_path then
    paths.ensure_dir(dir_path)
  end
end

local function read_file(path)
  local info = mp_utils.file_info(path)
  if not info or not info.is_file then
    return nil
  end
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    return nil
  end
  return content
end

function M.is_fresh(path, max_age)
  if not max_age then
    return false
  end
  local info = mp_utils.file_info(path)
  if not info or not info.is_file then
    return false
  end
  local age = os.time() - info.mtime
  return age <= max_age
end

function M.read(path, opts)
  opts = opts or {}
  if opts.max_age and not M.is_fresh(path, opts.max_age) then
    return nil
  end
  local content = read_file(path)
  if not content then
    return nil
  end
  local data = mp_utils.parse_json(content)
  if not data then
    return nil
  end
  if opts.validate and not opts.validate(data) then
    return nil
  end
  return data
end

local function rename_replace(tmp_path, path)
  local ok = os.rename(tmp_path, path)
  if ok then
    return true
  end
  os.remove(path)
  ok = os.rename(tmp_path, path)
  if ok then
    return true
  end
  return false
end

function M.write(path, data, opts)
  opts = opts or {}
  if data == nil then
    return false
  end
  local json = mp_utils.format_json(data)
  if not json then
    return false
  end
  ensure_parent_dir(path)
  if opts.atomic == false then
    local file = io.open(path, "w")
    if not file then
      return false
    end
    file:write(json)
    file:close()
    return true
  end

  local tmp_path = path .. ".tmp"
  local file = io.open(tmp_path, "w")
  if not file then
    return false
  end
  file:write(json)
  file:close()

  if rename_replace(tmp_path, path) then
    return true
  end

  os.remove(tmp_path)
  return false
end

return M

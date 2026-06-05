local title_guess = require "src.title_guess"
local t2s = require "src.dicts.t2s_chars"

local M = {}

local UTF8_PATTERN = "[\1-\127\194-\244][\128-\191]*"

local function append_unique(list, seen, value)
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

function M.to_simplified(text)
  if type(text) ~= "string" or text == "" then
    return text
  end
  return (text:gsub(UTF8_PATTERN, function(char)
    return t2s[char] or char
  end))
end

function M.normalized_variants(title)
  local variants = {}
  local seen = {}

  local normalized = title_guess.normalize_title(title)
  append_unique(variants, seen, normalized)

  local simplified = M.to_simplified(title)
  if simplified ~= title then
    append_unique(variants, seen, title_guess.normalize_title(simplified))
  end

  return variants
end

return M

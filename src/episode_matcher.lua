local M = {}

local function to_int(value)
  local n = tonumber(value)
  if not n then
    return nil
  end
  if n ~= math.floor(n) then
    return nil
  end
  return n
end

local function get_episode(ep_info)
  if not ep_info or type(ep_info) ~= "table" then
    return nil
  end
  if type(ep_info.episode) ~= "table" then
    return nil
  end
  return ep_info.episode
end

local function is_mainline(ep_info)
  local episode = get_episode(ep_info)
  local ep_type = episode and to_int(episode.type) or nil
  return ep_type == 0
end

local function find_by_field(episodes, parsed_no, field, mainline_only)
  for _, ep_info in ipairs(episodes or {}) do
    if (not mainline_only) or is_mainline(ep_info) then
      local episode = get_episode(ep_info)
      local value = episode and to_int(episode[field]) or nil
      if value and value == parsed_no then
        return ep_info
      end
    end
  end
  return nil
end

function M.match_by_number(episodes, parsed_no, opts)
  opts = opts or {}
  local parsed = to_int(parsed_no)
  if not parsed then
    return {
      target = nil,
      mode = nil,
      reason = nil,
      stats = {
        parsed_no = parsed_no,
        max_main_ep = nil,
        max_main_sort = nil,
        main_count = 0,
        total_count = type(episodes) == "table" and #episodes or 0,
      },
    }
  end

  local max_main_ep = nil
  local max_main_sort = nil
  local main_count = 0
  for _, ep_info in ipairs(episodes or {}) do
    if is_mainline(ep_info) then
      main_count = main_count + 1
      local episode = get_episode(ep_info)
      local ep_no = episode and to_int(episode.ep) or nil
      local sort_no = episode and to_int(episode.sort) or nil
      if ep_no and (not max_main_ep or ep_no > max_main_ep) then
        max_main_ep = ep_no
      end
      if sort_no and (not max_main_sort or sort_no > max_main_sort) then
        max_main_sort = sort_no
      end
    end
  end

  local stats = {
    parsed_no = parsed,
    max_main_ep = max_main_ep,
    max_main_sort = max_main_sort,
    main_count = main_count,
    total_count = type(episodes) == "table" and #episodes or 0,
  }

  local target = find_by_field(episodes, parsed, "ep", true)
  if target then
    return {
      target = target,
      mode = "ep",
      reason = "ep_exact",
      stats = stats,
    }
  end

  target = find_by_field(episodes, parsed, "sort", true)
  if target then
    local reason = "sort_fallback"
    if max_main_ep and parsed > max_main_ep then
      reason = "sort_fallback_parsed_gt_max_ep"
    end
    return {
      target = target,
      mode = "sort",
      reason = reason,
      stats = stats,
    }
  end

  target = find_by_field(episodes, parsed, "ep", false)
  if target then
    return {
      target = target,
      mode = "ep",
      reason = "ep_exact",
      stats = stats,
    }
  end

  target = find_by_field(episodes, parsed, "sort", false)
  if target then
    local reason = "sort_fallback"
    if max_main_ep and parsed > max_main_ep then
      reason = "sort_fallback_parsed_gt_max_ep"
    end
    return {
      target = target,
      mode = "sort",
      reason = reason,
      stats = stats,
    }
  end

  return {
    target = nil,
    mode = nil,
    reason = nil,
    stats = stats,
  }
end

return M

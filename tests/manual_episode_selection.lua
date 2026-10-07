-- Run from the repository root:
-- mpv --no-config --idle=yes --vo=null --ao=null --script=tests/manual_episode_selection.lua
-- All network and persistence dependencies are mocked; user data is never touched.
local host = require "mp"
local host_log = host.msg.log
package.path = "./?.lua;" .. package.path
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = clone(v) end
  return result
end

local function run()
  local files = {"main.lua", "src/bangumi_api.lua", "src/db.lua", "src/ui_menu.lua",
    "src/services/manual_binding.lua", "src/services/sync_context.lua",
    "src/services/stream_context.lua", "src/services/episode_status.lua"}
  for _, file in ipairs(files) do check(loadfile(file), "syntax: " .. file) end
  local path = "D:/Anime/unknown.mkv"
  local messages, events, menus = {}, {}, {}
  local store, writes, fail_write = {}, 0, false
  local noop = function() end
  _G.mp = {
    msg = {info = noop, error = noop, warn = noop, verbose = noop},
    get_property = function(name) if name == "path" then return path end end,
    get_property_number = function(_, default) return default end,
    get_property_native = function() return false end,
    command_native = function(args) return args[2] end,
    commandv = noop, osd_message = noop, set_property = noop,
    get_script_name = function() return "test" end,
    register_script_message = function(name, fn) messages[name] = fn end,
    register_event = function(name, fn) events[name] = fn end,
    add_key_binding = noop, observe_property = noop,
    add_periodic_timer = function() return {kill = noop, resume = noop} end,
  }
  package.loaded["mp.utils"] = {
    join_path = function(a, b) return a .. "/" .. b end,
    file_info = function() return {is_file = true} end,
    parse_json = function(value) return value end,
  }
  package.loaded["src.paths"] = {DATA_PATH = "test-data"}
  package.loaded["src.core.json_store"] = {
    read = function(key) return clone(store[key]) end,
    write = function(key, value)
      if fail_write then return false end
      writes = writes + 1
      store[key] = clone(value)
      return true
    end,
  }
  local filename_episode = nil
  local utils = {
    is_protocol = function(value) return value and value:find("://", 1, true) ~= nil end,
    extract_info_from_filename = function() return {episode = filename_episode} end,
    fuzzy_match_title = function() return 1 end,
    stable_url_key = function(value) return value:gsub("%?.*$", "") end,
    url_decode = function(value) return value end,
  }
  package.loaded["src.utils"] = utils
  package.loaded["src.config"] = {config = {}, on_options_changed = noop}
  package.loaded["src.http"] = {}
  local api = require "src.bangumi_api"
  local offsets = {}
  api.get = function(_, params)
    offsets[#offsets + 1] = params.offset
    check(params.type == nil, "public episode list must include specials")
    local data = {}
    for i = params.offset + 1, math.min(params.offset + 100, 205) do data[#data + 1] = {id = i} end
    return {status_code = 200, body = {data = data, total = 205}}
  end
  local response = api.get_subject_episodes(10)
  check(#response.body.data == 205 and offsets[3] == 200, "all pages are loaded")
  api.get = function(_, params)
    if params.offset > 0 then return {status_code = 503} end
    return {status_code = 200, body = {data = {{id = 1}}, total = 2}}
  end
  check(api.get_subject_episodes(10).status_code == 503, "partial list must fail")
  api.get = function() return {status_code = 200, body = {data = {}, total = 2}} end
  check(api.get_subject_episodes(10).status_code == 502, "empty intermediate page must not masquerade as complete")
  api.get = function(_, params)
    check(params.episode_type == nil, "manual status request must include specials")
    return {status_code = 200, body = {data = {}, total = 0}}
  end
  api.get_user_episodes(10, {all_types = true})

  local binding = require "src.services.manual_binding"
  local main_ep = {id = 101, type = 0, ep = 1, sort = 1, name = "Main"}
  local special = {id = 202, type = 1, ep = 1, sort = 12.5, name_cn = "", name = "Special"}
  check(binding.save(10, special, "Show"), "save selection")
  check(binding.get().episode.id == 202, "restore selection from storage")
  path = "D:/Anime/other.mkv"
  check(binding.get() == nil, "do not inherit another file's episode")
  path = "https://example.test/watch?episode=1"
  binding.save(10, special, "Show")
  path = "https://example.test/watch?episode=2"
  check(binding.get() == nil, "different URL episode parameters need different bindings")
  path = "D:/Anime/unknown.mkv"
  fail_write = true
  check(not binding.save(10, main_ep, "Show") and binding.get().episode.id == 202, "failed write retains old binding")
  fail_write = false
  check(binding.episode_label(special):find("12.5", 1, true) ~= nil, "fractional episode labels")
  check(binding.episode_label(special):find("Special", 1, true) ~= nil, "empty translated title falls back")

  local db = {
    get = function() return nil end, get_folder_info = function() return nil end,
    get_path = function(id, kind) return tostring(math.floor(id / 10000)) .. "/" .. kind end,
    set_bgm_id = noop, set_episode_info = noop, set_manual_bgm_id = noop,
    prune = function() return 0 end,
  }
  package.loaded["src.db"] = db
  package.loaded["src.dandanplay_api"] = {}
  package.loaded["src.video_info"] = {get_url_info = function() return {filename = "unknown.mkv"} end}
  package.loaded["src.core.storage_gate"] = {resolve_storage = function() return {key = "test"} end}
  package.loaded["src.title_variants"] = {}
  local title_info = {normalized_title = "show", title = "Show"}
  package.loaded["src.title_guess"] = {
    get_current_title_info = function() return title_info end,
    get_default_search_query = function() return "Show" end,
  }
  local episodes = {data = {{type = 0, episode = main_ep}, {type = 2, episode = special}}}
  api.get_user_episodes = function(_, opts)
    check(opts.all_types, "manual matching must request all episode types")
    return {status_code = 200, body = clone(episodes)}
  end
  api.get_user_collection = function() return {status_code = 200, body = {type = 3}} end
  api.get_subject = function() return {status_code = 200, body = {id = 10, name = "Show"}} end
  local sync = require "src.services.sync_context"
  local result = sync.sync_context({force_refresh = true}).execute()
  check(result.status == "ok" and result.context.episode_info.bgmEpisodeId == 202, "manual local selection works without filename episode")
  filename_episode = 1
  result = sync.sync_context({force_refresh = true}).execute()
  check(result.context.episode_info.bgmEpisodeId == 202, "manual ID wins over ambiguous episode number")
  check(result.context.episode_info.manualEpisode, "manual matching identity survives context build")
  local status = require "src.services.episode_status"
  local computed = status.compute(result.context.episode_info, episodes)
  check(computed.bgm_episode_id == 202 and computed.status_value == 2, "status uses exact selected ID")
  computed = status.compute(result.context.episode_info, {data = {{type = 0, episode = main_ep}}})
  check(computed.bgm_episode_id == nil, "missing selected ID must not fall back to episode number or title")
  computed = status.compute(result.context.episode_info, {
    collection = {type = 2}, data = {{type = 0, episode = special}},
  })
  check(computed.status_value == 0, "watched subject must not imply an unwatched special is watched")
  package.loaded["src.stream_data"] = {save_subject = noop, bind_subject = function() return true end}
  local stream = require "src.services.stream_context"
  title_info = nil
  result = stream.sync_context({force_refresh = true}).execute()
  check(result.status == "ok" and result.context.episode_info.bgmEpisodeId == 202, "stream selection works with no parseable title")
  result = sync.sync_context({force_refresh = true, remote_url = "https://example.test/video.mkv"}).execute()
  check(result.status == "ok" and result.context.episode_info.bgmEpisodeId == 202, "remote file retains selected episode")

  -- Exercise actual main.lua script-message handlers with controlled dependencies.
  local init_calls = 0
  local context_result = result
  local init_stub = function()
    init_calls = init_calls + 1
    return {async = function(cb) cb.resp(clone(context_result)) end}
  end
  local refresh_options
  package.loaded["src.services.sync_context"] = {
    sync_context = init_stub,
    get_user_episodes_cached = function(_, _, opts)
      refresh_options = opts
      return clone(episodes)
    end,
  }
  package.loaded["src.services.stream_context"] = {sync_context = init_stub, bind_current_subject = function() return true end}
  package.loaded["src.services.bangumi_service"] = {}
  package.loaded["src.services.dandanplay_service"] = {}
  package.loaded["src.ui_menu"] = {
    format_menu_item = function(title) return {title = title, selectable = false} end,
    open_uosc_menu = function(props) menus[#menus + 1] = clone(props) end,
    update_uosc_menu = function(props) menus[#menus + 1] = clone(props) end,
    update_info_menu = noop, open_subject_search_menu = noop, clear_episode_list = noop,
  }
  local input_selection
  package.loaded["mp.input"] = {terminate = noop, select = function(props) input_selection = props end}
  _G.Options = {enable_auto_mark = false}
  dofile("main.lua")
  messages["uosc-version"]()
  api.get_subject_episodes = function() return {status_code = 200, body = {data = {main_ep, special}}} end
  local before = writes
  messages["bgm-select-subject"]("10", "Show")
  local menu = menus[#menus]
  check(menu.type == "menu_bgm_subject_episodes" and #menu.items == 3, "subject click opens all episodes plus return")
  check(writes == before and init_calls == 0, "opening episode list must not bind or initialize")
  local selected = menu.items[2].value
  messages["bgm-open-bgm-subject-search"]()
  messages["bgm-select-subject-episode"](selected[4], selected[5])
  check(writes == before and init_calls == 0, "return cancels selection")
  messages["bgm-select-subject"]("10", "Show")
  selected = menus[#menus].items[2].value
  path = "D:/Anime/another.mkv"
  messages["bgm-select-subject-episode"](selected[4], selected[5])
  check(writes == before and init_calls == 0, "stale menu cannot bind a different video")
  path = "D:/Anime/unknown.mkv"
  messages["bgm-select-subject"]("10", "Show")
  selected = menus[#menus].items[2].value
  messages["bgm-select-subject-episode"](selected[4], "999")
  check(writes == before, "unknown episode ID is rejected")
  messages["bgm-select-subject-episode"](selected[4], selected[5])
  check(binding.get().episode.id == 202 and init_calls == 1, "selected episode binds and reloads once")
  check(CurrentEpContext.episodes_path == "10/episodes_all", "selected episode uses the full-list cache")
  messages["bgm-info-menu-event"]({type = "activate", action = "refresh"})
  check(refresh_options.all_types and CurrentEpisodeInfo.bgmEpisodeId == 202, "refresh retains the selected special episode")
  before = writes
  api.get_subject_episodes = function() return {status_code = 503} end
  messages["bgm-select-subject"]("10", "Show")
  check(menus[#menus].items[1].selectable == false and writes == before, "request failure preserves binding")
  api.get_subject_episodes = function() return {status_code = 200, body = {data = {}}} end
  messages["bgm-select-subject"]("10", "Show")
  check(menus[#menus].items[1].selectable == false and writes == before, "empty list preserves binding")
  api.get_subject_episodes = function() return {status_code = 200, body = {data = {main_ep, special}}} end
  _G.UoscAvailable = false
  messages["bgm-select-subject"]("10", "Show")
  check(#input_selection.items == 2, "native menu lists every episode")
  input_selection.submit(1)
  check(binding.get().episode.id == 101, "native menu binds selected episode")
  messages["bgm-select-episode"]("100001")
  check(binding.get() == nil, "switching to dandanplay clears explicit Bangumi episode override")
end

local ok, err = xpcall(run, debug.traceback)
_G.mp = host
if ok then
  host_log("info", "PASS: " .. count .. " checks")
else
  host_log("error", err)
end
host.commandv("quit", ok and "0" or "1")

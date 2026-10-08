-- Run from the repository root:
-- mpv --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/episode_list.lua
local real_commandv = mp.commandv
local mp_utils = require "mp.utils"
local temporary_files = {}
package.path = "./?.lua;./?/init.lua;" .. package.path

local function run()
  for _, path in ipairs({"main.lua", "src/ui_menu.lua", "src/bangumi_api.lua", "src/http.lua", "src/services/episode_status.lua"}) do
    assert(loadfile(path))
  end
  package.loaded["src.utils"] = {format_json = mp_utils.format_json}
  package.loaded["src.title_guess"] = {get_default_search_query = function() return "" end}
  package.loaded["src.db"] = {}
  package.loaded["src.core.json_store"] = {}
  package.loaded["src.episode_matcher"] = {}
  package.loaded["src.paths"] = {DATA_PATH = "."}
  package.loaded["src.config"] = {config = {access_token = "test-token", bgm_proxy = "http://test-proxy"}}
  local menu, root, submenu_id, selected_index, menu_action
  mp.commandv = function(_, _, action, json, arg, id)
    if action == "select-menu-item" then
      assert(json == "menu_bgm_info" and id == "menu_bgm_episode_list")
      selected_index = tonumber(arg)
      return
    end
    assert(action == "open-menu" or action == "update-menu")
    root = assert(mp_utils.parse_json(json))
    assert(root.type == "menu_bgm_info", "the info menu must remain the root")
    submenu_id, menu_action = arg, action
    menu = root.items[3].items and root.items[3] or root
  end
  local ui = require "src.ui_menu"
  local state = {UoscAvailable = true, EpisodeProgressText = "1 / 24", EpisodeStatusText = "未看"}
  ui.open_info_menu(state)
  assert(menu.items[3].value[3] == "bgm-open-episode-list")
  for _, count in ipairs({24, 72, 1501}) do
    local data = {data = {}}
    for i = count, 1, -1 do
      data.data[#data.data + 1] = {type = 0, episode = {id = i, type = 0, sort = i, name = "Episode " .. i}}
    end
    state.CurrentEpisodeInfo = {animeTitle = "测试番剧", bgmEpisodeId = count - 1}
    state.EpisodesData = {data = {{type = 2, episode = {id = count - 1}}}}
    ui.show_episode_list(state, data)
    assert(#menu.items == count + 1)
    assert(selected_index == count)
    assert(submenu_id == "menu_bgm_episode_list")
    assert(root.items[3].id == submenu_id and #root.items == 6)
    assert(root.items[3].title == "进 度  1 / 24")
    assert(menu.items[1].value[2] == "uosc/menu-back" and menu.items[1].keep_open)
    assert(menu.items[count].active and menu.items[count].hint == "播放中 · 已看")
    assert(menu.items[2].title == "第1话  Episode 1")
    assert(menu.search_style == "on_demand")
    assert(data.data[1].episode.id == count, "must not reorder the source cache")
  end
  state.CurrentEpisodeInfo = {bgmEpisodeId = 22}
  state.EpisodesData = {collection = {type = 2}}
  ui.show_episode_list(state, {data = {
    {type = 0, episode = {id = 22, type = 1, sort = 0.5, name_cn = "特别篇"}},
    {type = 0, episode = {id = 21, type = 0, sort = 12.5, name_cn = "", name = "Original title"}},
    {type = 0, episode = {id = 23, type = 2, sort = 1}},
  }})
  assert(menu.items[2].title == "第12.5话  Original title")
  assert(menu.items[2].hint == "已看")
  assert(menu.items[3].title == "SP 0.5  特别篇")
  assert(menu.items[3].hint == "播放中 · 未看")
  assert(menu.items[4].title == "OP 1  暂无标题")
  ui.show_episode_list({}, {data = {}})
  assert(menu.items[2].title == "暂无单集信息")
  ui.show_episode_list({EpisodeListFailed = true}, nil, "加载失败，请重试")
  assert(menu.items[3].value[3] == "bgm-open-episode-list")
  ui.show_episode_list(state, {data = {}}, nil, true)
  assert(menu_action == "update-menu" and submenu_id == nil, "completion must not reopen or navigate the menu")
  ui.update_info_menu(state)
  assert(root.items[3].items, "progress updates must preserve the submenu")
  state.EpisodesData = {data = {{type = 2, episode = {id = 22, sort = 1}}}}
  selected_index = nil
  ui.update_info_menu(state)
  assert(menu.items[2].hint == "播放中 · 已看" and selected_index == nil,
    "cache refresh must update statuses without moving the selection")
  ui.open_info_menu(state)
  assert(not root.items[3].items, "reopening info starts a fresh list")

  -- Test the real transport parser in both existing synchronous and new async modes.
  local http = require "src.http"
  local command, receive
  mp.command_native = function(args)
    command = args
    return {status = 0, stdout = '{"ok":true}\n__HTTP_STATUS__:200'}
  end
  mp.command_native_async = function(args, callback)
    command, receive = args, callback
    return 42
  end
  assert(http.get("https://example.invalid").body.ok)
  local response
  assert(http.get("https://example.invalid", {timeout = 30, callback = function(res) response = res end}) == 42)
  assert(table.concat(command.args, " "):find("--max-time 30", 1, true))
  receive(true, {status = 0, stdout = '{"data":[]}\n__HTTP_STATUS__:401'})
  assert(response.status_code == 401)
  receive(false, nil)
  assert(response.status_code == 0)

  -- Drive pagination without making network requests.
  local requests, aborted = {}, nil
  http.get = function(url, options)
    requests[#requests + 1] = {url = url, options = options}
    return #requests
  end
  mp.abort_async_command = function(id) aborted = id end
  local api = require "src.bangumi_api"
  local result, calls
  local function start()
    requests, result, calls = {}, nil, 0
    return api.get_user_episodes_async(123, function(value) result, calls = value, calls + 1 end)
  end
  start()
  assert(requests[1].options.params.episode_type == 0)
  assert(requests[1].options.proxy == "http://test-proxy")
  assert(requests[1].options.headers.Authorization == "Bearer test-token")
  local page = {}
  for i = 1, 1000 do page[i] = {episode = {id = i}} end
  requests[1].options.callback({status_code = 200, body = {data = page, total = 1001}})
  assert(calls == 0 and requests[2].options.params.offset == 1000)
  requests[2].options.callback({status_code = 200, body = {data = {{episode = {id = 1001}}}, total = 1001}})
  assert(calls == 1 and #result.data == 1001)
  start()
  requests[1].options.callback({status_code = 200, body = {data = {}, total = 0}})
  assert(calls == 1 and #result.data == 0)
  start()
  requests[1].options.callback({status_code = 200, body = {data = {{episode = {id = 1}}}, total = 2}})
  requests[2].options.callback({status_code = 503, body = {}})
  assert(calls == 1 and result == nil, "partial failures must not appear complete")
  start()
  requests[1].options.callback({status_code = 200, body = {data = {}, total = 2}})
  assert(calls == 1 and result == nil)
  local cancel = start()
  cancel()
  requests[1].options.callback({status_code = 200, body = {data = {}, total = 0}})
  assert(aborted == 1 and calls == 0)

  -- Exercise the actual message handlers, including late responses after closing.
  local messages, events, pending, shown = {}, {}, {}, {}
  -- Use real JSON disk reads/writes under mpv, and count accesses.
  package.loaded["src.paths"].ensure_dir = function() end
  local json_store = assert(loadfile("src/core/json_store.lua"))()
  package.loaded["src.core.json_store"] = json_store
  local read, disk_reads = json_store.read, 0
  json_store.read = function(...)
    disk_reads = disk_reads + 1
    return read(...)
  end
  local cache_path = os.tmpname()
  temporary_files[#temporary_files + 1] = cache_path
  package.loaded["src.db"].get_path = function() return cache_path end
  Options = {enable_auto_mark = false}
  package.loaded["src.config"].on_options_changed = function() end
  package.loaded["src.db"].prune = function() return 0 end
  package.loaded["src.utils"].is_protocol = function() return false end
  for _, name in ipairs({"sync_context", "stream_context", "bangumi_service", "dandanplay_service"}) do
    package.loaded["src.services." .. name] = {}
  end
  package.loaded["mp.input"] = {}
  mp.register_script_message = function(name, fn) messages[name] = fn end
  mp.register_event = function(name, fn) events[name] = fn end
  mp.add_key_binding = function() end
  mp.commandv = function() end
  ui.update_info_menu = function() end
  ui.open_info_menu = function() end
  ui.show_episode_list = function(info, data, message, update)
    shown[#shown + 1] = {request = info.EpisodeListRequest, data = data, message = message, update = update}
  end
  api.get_user_episodes_async = function(_, callback)
    local request = {callback = callback}
    pending[#pending + 1] = request
    return function() request.cancelled = true end
  end
  assert(loadfile("main.lua"))()
  messages["uosc-version"]()
  messages["bgm-open-episode-list"]()
  assert(shown[#shown].message:find("尚未匹配", 1, true))
  local memory_data = {data = {{type = 2, episode = {id = 10, sort = 1, name = "Cached episode"}}}}
  CurrentEpContext = {bgm_id = 123, episodes_data = memory_data, episodes_path = cache_path}
  messages["bgm-open-episode-list"]()
  assert(shown[#shown].data == memory_data and disk_reads == 0 and #pending == 0,
    "memory cache must display immediately without disk or network access")
  assert(memory_data.data[1].type == 2, "locally watched episodes must remain watched")
  assert(json_store.write(cache_path, memory_data))
  CurrentEpContext = {bgm_id = 123, runtime_episode_id = 1230001}
  messages["bgm-open-episode-list"]()
  assert(disk_reads == 1 and #pending == 0 and CurrentEpContext.episodes_path == cache_path)
  assert(CurrentEpContext.episodes_data.data[1].episode.name == "Cached episode")
  messages["bgm-open-episode-list"]()
  assert(disk_reads == 1 and #pending == 0, "disk cache must be retained in memory")
  CurrentEpContext.episodes_data = {data = {}}
  messages["bgm-open-episode-list"]()
  assert(#shown[#shown].data.data == 0 and #pending == 0, "an empty cache is still valid")
  CurrentEpContext = {bgm_id = 123}
  messages["bgm-open-episode-list"]()
  local token = shown[#shown].request
  messages["bgm-back-info-menu"]()
  local before = #shown
  pending[1].callback({data = {}})
  assert(pending[1].cancelled and #shown == before)
  messages["bgm-open-episode-list"]()
  messages["bgm-cancel-episode-list"](tostring(token))
  assert(not pending[2].cancelled, "stale close events must not cancel a new load")
  pending[2].callback({data = {}})
  assert(shown[#shown].data and shown[#shown].request == nil and shown[#shown].update == true)
  messages["bgm-open-episode-list"]()
  assert(#pending == 2, "a successful fallback must be reused")
  CurrentEpContext = {bgm_id = 123}
  messages["bgm-open-episode-list"]()
  events["end-file"]({reason = "stop"})
  before = #shown
  pending[3].callback({data = {}})
  assert(pending[3].cancelled and #shown == before)
  -- Invalid disk cache falls back to a request and is replaced only on success.
  assert(json_store.write(cache_path, {data = "invalid"}))
  CurrentEpContext = {bgm_id = 123, episodes_data = false, episodes_path = cache_path}
  messages["bgm-open-episode-list"]()
  assert(#pending == 4 and shown[#shown].request)
  pending[4].callback(memory_data)
  assert(read(cache_path).data[1].type == 2 and CurrentEpContext.episodes_data == memory_data)
  CurrentEpContext.episodes_data = nil
  messages["bgm-open-episode-list"]()
  assert(#pending == 4 and shown[#shown].data.data[1].type == 2,
    "fallback results must be reusable from disk")
  CurrentEpContext = {bgm_id = 123}
  messages["bgm-open-episode-list"]()
  CurrentEpContext.episodes_data = memory_data
  pending[5].callback({data = {{type = 0, episode = {id = 10}}}})
  assert(shown[#shown].data == memory_data, "late network data must not overwrite new local state")
  CurrentEpContext = {bgm_id = 123}
  messages["bgm-open-episode-list"]()
  pending[6].callback(nil)
  assert(CurrentEpContext.episodes_data == nil and shown[#shown].message == "加载失败，请重试")
end

local ok, err = xpcall(run, debug.traceback)
for _, path in ipairs(temporary_files) do os.remove(path) end
if ok then
  print("PASS: episode list UI, memory/disk cache, fallback persistence, pagination, HTTP, and lifecycle checks")
else
  mp.msg.error(err)
end
real_commandv("quit", ok and "0" or "1")

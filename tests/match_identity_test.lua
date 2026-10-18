-- Run from the repository root:
-- mpv --no-config --load-scripts=no --idle=yes --vo=null --ao=null --script=tests/match_identity_test.lua
local real_mp = mp
local mp_utils = require "mp.utils"
local script_dir = debug.getinfo(1, "S").source:match("^@(.+)[/\\][^/\\]+$")
package.path = script_dir .. "/../?.lua;" .. package.path

local passed = 0
local function check(condition, message)
  assert(condition, message)
  passed = passed + 1
end

local function run()
  local function check_syntax(dir)
    for _, name in ipairs(mp_utils.readdir(dir, "files") or {}) do
      if name:match("%.lua$") then
        local chunk, err = loadfile(dir .. "/" .. name)
        check(chunk ~= nil, err)
      end
    end
    for _, name in ipairs(mp_utils.readdir(dir, "dirs") or {}) do
      check_syntax(dir .. "/" .. name)
    end
  end
  check_syntax(script_dir .. "/../src")
  local main_chunk, main_err = loadfile(script_dir .. "/../main.lua")
  check(main_chunk ~= nil, main_err)

  -- 所有文件、配置、API 和绑定均隔离在内存中，不读取真实追番数据。
  local files, metadata, episode_info = {}, {}, {}
  local props = {platform = "windows"}
  package.loaded["src.config"] = {config = {storage_groups = {
    {key = "storage1", storages = {"D:/Anime/"}, batch_sync_threshold = 1},
  }}}
  package.loaded["src.paths"] = {DATA_PATH = "test-memory", ensure_dir = function() return true end}
  local original_file_info, original_open = mp_utils.file_info, io.open
  mp_utils.file_info = function(path)
    if files[path] or path:match("^[DE]:/Anime/") then return {is_file = true} end
    if path == "test-memory/metadata" then return {is_dir = true} end
    return nil
  end
  io.open = function(path, mode)
    assert(path:match("^test%-memory/"), "unexpected IO: " .. path)
    if mode == "r" and not files[path] then return nil end
    local value = mode == "w" and "" or files[path]
    return {
      read = function() return value end,
      write = function(_, data) value = value .. data end,
      close = function() files[path] = value end,
    }
  end
  mp = setmetatable({
    get_property = function(name) return props[name] end,
    get_property_native = function(name) return props[name] end,
    get_property_number = function(name) return props[name] end,
    command_native = function(args)
      assert(args[1] == "normalize-path", "unexpected command")
      return args[2]:gsub("\\", "/")
    end,
  }, {__index = real_mp})

  local identity = require "src.match_identity"
  local db = require "src.db"
  local function current(path, metadata_title)
    local filename = path:match("([^/\\]+)$")
    props.path = path
    props["filename/no-ext"] = filename:gsub("%.[^.]+$", "")
    props["media-title"] = metadata_title or filename
    return identity.get_current()
  end
  local function reset()
    files["test-memory/data.json"] = "{}"
    for key in pairs(metadata) do metadata[key] = nil end
    for key in pairs(episode_info) do episode_info[key] = nil end
  end
  local cases = {
    {"D:/Anime/Example/Season 1/Example - 01.mkv", "example", 1, 1, "series"},
    {"D:/Anime/Example/Season 2/Example - 01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Season 2/01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/S02/EP02.mkv", "example", 2, 2, "series"},
    {"D:/Anime/Example/第2季/[03].mkv", "example", 2, 3, "series"},
    {"D:/Anime/Example/第二季/第4话.mkv", "example", 2, 4, "series"},
    {"D:/Anime/Example 第二季/01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example S02/01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example 2nd Season/01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/SEASON02/01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/第十二季/01.mkv", "example", 12, 1, "series"},
    {"D:/Anime/Example/Season 2/S02E01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Season 2/[Group] [01] [1080p].mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Season 2/[Group] Example [01] [1080p].mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Example S02E01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Example.Season.2.-.01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Example 第二季 第01话.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Example S02 E01.mkv", "example", 2, 1, "series"},
    {"D:/Anime/Example/Example - 01.mkv", "example", nil, 1, "directory"},
    {"D:/Anime/Show A/01.mkv", "showa", nil, 1, "directory"},
    {"D:/Anime/Show A/02.mkv", "showa", nil, 2, "directory"},
    {"D:/Anime/Show B/01.mkv", "showb", nil, 1, "directory"},
    {"D:/Anime/01.mkv", nil, nil, 1, "file"},
    {"D:/Anime/Season 2/01.mkv", nil, 2, 1, "file"},
    {"D:/Anime/Downloads/01.mkv", nil, nil, 1, "file"},
    {"D:/Anime/Example/Season 1/Example S02E01.mkv", "example", 2, 1, "file"},
    {"D:/Anime/Example/Season 0/01.mkv", "example", 0, 1, "file"},
    {"D:/Anime/Example/Specials/01.mkv", "specials", nil, 1, "file"},
    {"D:/Anime/Other/Example S02E01.mkv", "example", 2, 1, "file"},
  }
  for _, case in ipairs(cases) do
    local result = current(case[1])
    local diagnostic = case[1] .. ": " .. mp_utils.format_json(result)
    check(result.normalized_title == case[2] and result.season == case[3]
      and result.episode_no == case[4] and result.scope == case[5], diagnostic)
    check(identity.is_cache_key(result.cache_key), "invalid key: " .. diagnostic)
  end
  local first = current("D:/Anime/Show A/01.mkv").cache_key
  check(first == current("D:/Anime/Show A/02.mkv").cache_key, "numeric episodes must share a series")
  check(first ~= current("D:/Anime/Show B/01.mkv").cache_key, "different shows must not share a key")
  check(first ~= current("E:/Anime/Show A/01.mkv").cache_key, "unknown season must remain directory scoped")
  check(first == current("D:\\Anime\\Show A\\01.mkv", "Changing embedded episode title").cache_key,
    "local key must not depend on embedded media title")
  check(current("D:/Anime/Example/Season 2/01.mkv").cache_key
    == current("E:/Anime/Example/S02/02.mkv").cache_key, "known seasons should share across directories")
  check(current("D:/Anime/Downloads/Show A - 01.mkv").cache_key
    ~= current("D:/Anime/Downloads/Show B - 01.mkv").cache_key, "shared directories still need title isolation")
  check(current("D:/Anime/Downloads/01.mkv").cache_key
    ~= current("D:/Anime/Downloads/02.mkv").cache_key, "unknown titles need per-file isolation")
  check(first == current("d:/anime/show a/01.mkv").cache_key, "Windows path casing should not change identity")
  props.platform = "linux"
  check(identity.for_local_path("/Anime/Example/01.mkv").cache_key
    ~= identity.for_local_path("/anime/Example/01.mkv").cache_key, "POSIX paths must remain case sensitive")
  props.platform = "windows"

  reset()
  local s1 = "D:/Anime/Example/Season 1/Example - 01.mkv"
  local s2 = "D:/Anime/Example/Season 2/Example - 01.mkv"
  local key1, key2 = current(s1).cache_key, current(s2).cache_key
  db.set_dandanplay_id(s1, 1010001, key1)
  db.set_manual_bgm_id(s1, 1001, key1)
  check(db.get({path = s2, cache_key = key2}) == nil and db.get_cache_info(key2) == nil,
    "season two must not read season one's episode or binding")
  local a1, a2, b1 = "D:/Anime/Show A/01.mkv", "D:/Anime/Show A/02.mkv", "D:/Anime/Show B/01.mkv"
  local ak = current(a1).cache_key
  db.set_manual_bgm_id(a1, 2002, ak)
  check(db.get_cache_info(current(a2).cache_key).bgm_id == 2002, "next numeric episode should inherit binding")
  check(db.get({path = b1, cache_key = current(b1).cache_key}) == nil, "unrelated show inherited binding")

  package.loaded["src.core.json_store"] = {
    read = function(path, opts)
      local data = metadata[path]
      if data and opts and opts.validate and not opts.validate(data) then return nil end
      return data
    end,
    write = function(path, data) metadata[path] = data; return true end,
  }
  package.loaded["src.bangumi_api"] = {
    get_user_episodes = function(id, opts)
      local data = {
        {type = 0, episode = {id = id * 100 + 1, ep = 1, sort = 1, type = 0}},
        {type = 0, episode = {id = id * 100 + 2, ep = 2, sort = 2, type = 0}},
      }
      if opts.all_types then data[#data + 1] = {type = 0, episode = {id = id * 100 + 99, ep = 1, sort = 1, type = 1}} end
      return {status_code = 200, body = {data = data}}
    end,
    get_user_collection = function() return {status_code = 200, body = {type = 3}} end,
    get_subject = function(id) return {status_code = 200, body = {id = id, name = "Show A"}} end,
  }
  package.loaded["src.video_info"] = {get_info = function(path) return {filename = path} end}
  local match_calls = 0
  package.loaded["src.dandanplay_api"] = {
    match = function()
      match_calls = match_calls + 1
      return {{episodeId = 1010001, animeId = 101, animeTitle = "Show A", episodeTitle = "One"}}
    end,
    get_anime_info = function(id)
      return {animeId = id, animeTitle = "Show A", bangumiUrl = "https://bgm.tv/subject/2002", episodes = {
        {episodeId = id * 10000 + 1, episodeTitle = "One"},
        {episodeId = id * 10000 + 2, episodeTitle = "Two"},
      }}
    end,
  }
  db.get_episode_info = function(id) return episode_info[id] end
  db.set_episode_info = function(id, data) episode_info[id] = data; return true end
  local binding = require "src.services.manual_binding"
  local sync = require "src.services.sync_context"
  local function execute(path, opts)
    current(path)
    local result = sync.sync_context(opts or {}).execute()
    check(result.status == "ok", path .. ": " .. mp_utils.format_json(result))
    return result.context
  end

  current(a1)
  binding.save(2002, {id = 200299, ep = 1, sort = 1, type = 1}, "Show A")
  check(execute(a1).episode_info.bgmEpisodeId == 200299, "manual episode must take priority")
  check(execute(a1, {force_refresh = true}).episode_info.bgmEpisodeId == 200299, "refresh lost manual episode")
  check(execute(a2).episode_info.bgmEpisodeId == 200202, "next file must inherit only the subject")
  local service = require "src.services.bangumi_service"
  check(service.fetch_episodes(true, {bgm_id = 2002}).execute().success,
    "refresh must read the same directory-scoped binding")

  reset()
  match_calls = 0
  execute(a1)
  check(execute(a2).episode_id == 1010002 and match_calls == 1, "numeric autoload should reuse matched series")
  check(execute(a1).episode_id == 1010001 and match_calls == 1, "replay should reuse exact file record")
  execute(b1)
  check(match_calls == 2, "different show should request a fresh match")

  reset()
  match_calls = 0
  execute(s1)
  execute(s2)
  check(match_calls == 2, "a different season must request a fresh match")

  reset()
  match_calls = 0
  execute("D:/Anime/Downloads/01.mkv")
  execute("D:/Anime/Downloads/02.mkv")
  check(match_calls == 2, "unknown files must not autoload another file's episode")
  execute("D:/Anime/Downloads/01.mkv")
  check(match_calls == 2, "unknown file should retain its own matching cache")

  reset()
  match_calls = 0
  execute("D:/Anime/Example/Season 1/Example S02E01.mkv")
  execute("D:/Anime/Example/Season 1/Example S02E02.mkv")
  check(match_calls == 2, "conflicting seasons must not share autoload records")

  -- 网络标题解析保持原有行为；缺少可靠季数的完整文件按完整 URL 隔离。
  local network1 = current("https://example.test/play?id=1").cache_key
  local network2 = current("https://example.test/play?id=2").cache_key
  check(network1 ~= network2, "different URL queries must not share file cache")
  local streamed = current("https://example.test/Example.S02E01.mkv")
  check(streamed.cache_key == "example|s2", "explicit network title should keep its series identity")
  local stream_title = require("src.title_guess").get_current_title_info()
  check(stream_title.season == 2 and stream_title.episode_no == 1, "stream title parsing changed")
  props.path = nil
  check(identity.get_current().cache_key == nil, "no video must not create a key")

  io.open, mp_utils.file_info = original_open, original_file_info
end

local ok, err = xpcall(run, debug.traceback)
mp = real_mp
if ok then
  mp.msg.info(string.format("PASS: %d assertions", passed))
else
  mp.msg.error(err)
end
mp.commandv("quit", ok and 0 or 1)

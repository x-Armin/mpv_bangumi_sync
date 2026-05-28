# mpv_bangumi_sync

使用 mpv 播放动画时，自动同步 Bangumi 追番进度，并支持显示番剧信息。

## 功能
- 自动识别番剧并匹配Bangumi条目
- 当单集被标记为“已看”时（到达进度阈值触发），会检测条目收藏状态；若未收藏/非“在看”会自动更新为“在看”并在左上角提示
- 观看进度达到配置阈值（默认0.9）时自动将Bangumi这一集标为看过，并在左上角弹出提示
- 支持“自动点格子（开启/禁用）”开关；禁用时仅展示信息，不会写回Bangumi状态
- 默认绑定"Alt+o"打开番剧信息表，界面如下
![番剧信息](doc/anime-info.png)
![番剧信息](doc/anime-info2.png)

## 依赖
- **curl**（HTTP 请求）
- **ffprobe**（视频信息提取）
（一般电脑都装了，不用管）

## 安装
下载 zip 解压到mpv的插件目录，mpv-lazy如下：
```
mpv-lazy/portable_config/scripts/mpv_bangumi_sync
```

## 数据目录
用来存放缓存的弹弹play id以及动画和单集的信息
- `portable_config/mpv_bangumi_sync_data/`


## 配置
- 将`mpv_bangumi_sync.conf`复制到 mpv 配置目录
`mpv-lazy/portable_config/script-opts`

- 如果要添加uosc按钮，可以在uosc.conf中的"controls="字段添加
`command:info:script-message open-bangumi-info?番剧信息`
放在喜欢的位置即可

- 进度阈值（0~1）：`progress_mark_threshold`，默认 0.9
- Storage 1 批量同步阈值：`storage1_batch_sync_threshold`，默认 1
- Storage 2 批量同步阈值：`storage2_batch_sync_threshold`，默认 4
- 批量同步阈值设为 0 时，不按数量自动同步；退出/关闭自动点格子时仍会同步 pending
- Bangumi API 代理：`bgm_proxy`，默认留空表示不使用代理；该代理只作用于 Bangumi API，不影响弹弹play API
  - 示例：`bgm_proxy=http://127.0.0.1:7890`
  - 示例：`bgm_proxy=socks5h://127.0.0.1:7890`
  - 带用户名密码：`bgm_proxy=http://username:password@127.0.0.1:7890`
  - 用户名或密码包含特殊字符时请使用 URL 编码，例如密码 `pa:ss@word` 应写成 `pa%3Ass%40word`
- 自动点格子开关：`enable_auto_mark`，默认 `yes`
  - `yes`：自动同步条目状态和单集状态
  - `no`：仅展示信息，不同步状态
## 使用
- 播放视频后自动匹配番剧，进度达到阈值（默认 0.9）时标记为“已看”，并在此时检测/修正条目收藏状态
- 若当前集打开时已是“已看”，不会再启动进度检测定时器
- `Alt+o` 打开番剧信息窗口（依赖 uosc）
- 信息窗口内可查看标题/进度/状态；点击“手动匹配”后可选择：
  - 弹弹play 搜索（原流程）
  - Bangumi 搜索（会将当前目录绑定到选中的 Bangumi 条目）
- 信息窗口内“自动点格子”一栏提供常驻“切换”按钮，可直接在面板里开启/禁用
- 右侧“刷新”会重新拉取 Bangumi 剧集信息并更新显示
- 插件只在配置文件的 `storage1` 和 `storage2` 指定目录下生效
- `storage1` 和 `storage2` 使用完全一致的批量同步逻辑，区别只是默认阈值不同
- 播放达到进度阈值后会先记录到 pending；当该 storage 组的 pending 数量达到阈值时立即批量同步
- `storage1_batch_sync_threshold=1` 时，每次点格子都会立即触发批量同步，表现接近原来的立即同步
- `enable_auto_mark` 播放中切换实时生效：
  - 开启 -> 禁用：会先执行一次 pending 批量同步，再停用自动点格子
  - 禁用 -> 开启：满足条件时恢复进度检测

## 注意
- 本插件仅在Windows 10环境测试过，未测试过Linux环境。
- 插件只在 `storage1` 和 `storage2` 指定的目录下生效
- 关闭 mpv 时会同步尚未 flush 的 pending 记录；pending 较多时可能略微影响退出速度。
- 如果同一路径同时匹配两个 storage 组，会使用匹配路径更长、更具体的那一组配置。

## 后续开发计划
本项目只专注与bgm相关的功能，后续也不会添加比较重型的功能


✅ 适配 uosc，添加同步信息窗口

✅ 优化缓存匹配更新逻辑，目前部分场景会存在匹配不到信息又不更新缓存的bug，近期会修复（一月番好看的太多了，没时间debug）

✅ 适配批量同步逻辑，避免短时间每集都标记一次导致刷屏 Bangumi 时间线

⬜️ 从api获取信息的流程改为异步，这样不阻塞打开信息窗口。（mpv lua似乎没有线程的概念，方案还需再想想，改动会比较大）



## 感谢
本项目大量借用 [mpv_bangumi](https://github.com/slqy123/mpv_bangumi)的代码，在此基础上删除了弹幕功能，移除了对 Python 和闭源可执行程序的依赖，纯lua实现。


番剧信息窗口依赖于[uosc UI框架](https://github.com/tomasklaen/uosc)。要使用该功能请为mpv播放器安装uosc。uosc的安装步骤可以参考其[官方安装教程](https://github.com/tomasklaen/uosc?tab=readme-ov-file#install)。如果使用[MPV_lazy](https://github.com/hooke007/MPV_lazy)等内置了uosc的懒人包则只需安装本插件即可。

PS：⚠️⚠️⚠️之前没用过lua，所以大部分代码是AI写，我负责review和debug，使用上有bug可以提issue，有时间就会尽力解决

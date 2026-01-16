# mpv_bangumi_sync

使用 mpv 播放动画时，自动同步 Bangumi 追番进度。

## 功能
- 自动识别番剧并匹配Bangumi条目
- 播放视频后，如果这个番剧在Bangumi没有收藏，自动标为在看
- 观看进度到80%时自动将Bangumi这一集标为看过
- 默认绑定"Alt+o"打开番剧信息表，界面如下
![番剧信息](doc/anime-info.png)

## 依赖
- **curl**（HTTP 请求）
- **ffprobe**（视频信息提取）

## 安装
把仓库克隆或下载 zip 解压到mpv的插件目录，mpv-lazy如下：
```
mpv-lazy/portable_config/scripts/mpv_bangumi_sync
```

## 配置
在 mpv 配置目录创建 `script-opts/mpv_bangumi_sync.conf`：
```
portable_config/script-opts/mpv_bangumi_sync.conf
```

示例配置：
```conf
# Bangumi 访问令牌（必需）
# 获取地址：https://next.bgm.tv/demo/access-token
bgm_access_token=你的访问令牌

# 番剧存储目录（多个目录用分号/冒号分隔）
storages=D:/Anime;E:/Anime

```

## 使用
- 播放视频后会自动匹配并在进度到 80% 时标记为“已看”
- `Alt+o` 打开当前番剧 Bangumi 页面
- `Alt+m` 手动匹配番剧

## 数据目录
- `portable_config/mpv_bangumi_sync_data/`

## 注意
- 插件只在 `storages` 指定的目录下生效

## 后续开发计划
本项目只专注与bgm相关的功能，后续也不会添加比较重型的功能


✅ 适配 uosc，添加同步信息窗口

⬜️ 适配补番逻辑，避免短时间每集都标记一次导致刷屏 Bangumi 时间线

⬜️ 优化缓存匹配更新逻辑，目前部分场景会存在匹配不到信息又不更新缓存的bug，近期会修复（一月番好看的太多了，没时间debug）



## 感谢
本项目大量借用 [mpv_bangumi](https://github.com/slqy123/mpv_bangumi)的代码，在此基础上删除了弹幕功能，移除了对 Python 和闭源可执行程序的依赖，纯lua实现。


番剧信息窗口依赖于[uosc UI框架](https://github.com/tomasklaen/uosc)。要使用该功能请为mpv播放器安装uosc。uosc的安装步骤可以参考其[官方安装教程](https://github.com/tomasklaen/uosc?tab=readme-ov-file#install)。如果使用[MPV_lazy](https://github.com/hooke007/MPV_lazy)等内置了uosc的懒人包则只需安装本插件即可。

PS：⚠️⚠️之前没用过lua，所以基本是AI写，我负责review，使用上有bug可以提issue，有时间会尽力解决

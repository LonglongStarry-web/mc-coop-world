# MC 双人共用世界

两个人共用同一份《我的世界》：存档、模组都放在这个仓库里，谁玩完了推上来，另一个人拉下去接着玩。

> **先说清楚一件事**：GitHub 不能当游戏服务器。仓库只负责「传文件」，做不到两个人同时在线实时同屏。
> 想要真正同时在线，看下面的【方案 B】。

---

## 两种玩法，先选一种

### 方案 A：轮流玩同一份存档（最省事）
```
你玩完 → push  →  朋友 pull → 玩 → push  →  你 pull → 玩 ...
```
- 优点：零成本、不用配网络，两个人只要有账号就能开工。
- 缺点：一次只能一个人玩，不能同时在线。

### 方案 B：一个人开服，两个人同时进（真正的「同时玩」）
一台电脑跑 Minecraft 服务端，另一个人通过 IP / 内网穿透连进来。
仓库在这里的作用是：保存服务端配置和模组列表，保证两边客户端和服务器一致，谁重装电脑都能一键还原。

两种方案可以并存，仓库结构不用改。

---

## 目录说明

| 目录 | 放什么 |
| --- | --- |
| `world/` | 存档。就是 `.minecraft\saves\` 下面那个世界文件夹的**整个内容** |
| `mods/` | 模组 `.jar`。方案 B 时服务端的 `mods/` 也用这份 |
| `scripts/` | 存档同步脚本（Windows PowerShell） |

---

## 首次准备

1. 复制你的世界文件夹内容到 `world/`
   ```bash
   # 示例：把本地世界「我的世界」拷进仓库
   robocopy "%APPDATA%\.minecraft\saves\我的世界" world /E
   ```
2. 模组 `.jar` 丢进 `mods/`
3. 提交推送：
   ```bash
   git add -A
   git commit -m "init: 初始存档与模组"
   git push
   ```

---

## 日常同步（Windows）

### 拉取：玩之前，把朋友的进度拿下来
```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull -WorldName 我的世界
```

### 推送：玩完之后，把自己的进度交上去
```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -WorldName 我的世界
```

脚本做了两件保护你的事：push 前不动远端、pull 前先把本地存档整份备份成
`<世界名>.bak-年月日-时分秒`，搞坏了改回原名就能回退。

不想用脚本的话，手动也只要两条命令：

```bash
# 拉取（仓库 → 本地）
robocopy world "%APPDATA%\.minecraft\saves\我的世界" /E /XF .gitkeep README.md

# 推送（本地 → 仓库），然后照常 git add / commit / push
robocopy "%APPDATA%\.minecraft\saves\我的世界" world /E
```

---

## 加协作者

网页：仓库页 → **Settings** → 左侧 **Collaborators** → **Add people** → 填对方的 GitHub 用户名 → 对方邮箱收到邀请，点接受后就有推送权限。

命令行：

```bash
gh api -X PUT repos/LonglongStarry-web/mc-coop-world/collaborators/对方用户名 -f permission=push
```

---

## 几条必须注意的（踩了会丢存档）

- **版本必须完全一致**：Java 版版本号、Forge/Fabric 版本、模组列表，差一个都可能崩或者读坏存档。改模组前先说一声。
- **同一次只能一个人写入**：两人同时改存档还都 push，Git 处理不了二进制的 `.mca`，只能二选一。约定好「现在谁在玩」。
- **玩之前先 pull，玩完立刻 push**，别攒着，攒越久分叉越麻烦。
- **别删 `.gitattributes`**：里面那行 `* -text` 是安全带。Windows 上 Git 默认会把文件当文本做换行符转换，`.mca` 一被转换存档就废了。
- **别提交 `session.lock`、`logs/`、`crash-reports/`**，`.gitignore` 已经挡住了。
- **别在游戏开着的时候 push**，存档还在写，容易推出半截文件。先退出游戏。
- 仓库是**公开**的，内容任何人可见。想改私密：Settings → 最下方 Danger Zone → Change visibility。

---

## 存档太大怎么办

GitHub 单文件上限 100 MB，仓库建议控制在 1 GB 以内。探索范围很大的世界可能超。
真要长期玩、世界很大，两个选择：

1. **定期开新存档**，把老存档打包留个 tag 就行。
2. **改用 Git LFS**：`git lfs track "world/*.mca"` 之后照常用，但免费额度只有 1 GB 存储 + 1 GB/月流量，量小还行。

# MC 双人共用世界

从首次配置到日常交接，请阅读[双人存档使用指南](使用指南.md)。

两个人共用同一份《我的世界》：存档放在这个仓库里，谁玩完了推上来，另一个人拉下去接着玩。

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

| 路径 | 放什么 |
| --- | --- |
| `world/` | 存档。就是 `.minecraft\saves\` 下面那个世界文件夹的**整个内容** |
| `mods/` | 可选的手动存放目录，脚本只同步存档 |
| `game-dir.sample.txt` | 游戏目录的模板，复制改名成 `game-dir.txt` 填自己的路径 |
| `scripts/sync.ps1` | 同步脚本本体（PowerShell） |
| `pull.bat` | 双击 = 更新 GitHub 进度、备份并导入游戏存档 |
| `push.bat` | 双击 = 推送存档 |

`pull.bat` / `push.bat` 里只有一行调用，内容故意写成纯英文——`.bat` 是 cmd 按系统 OEM 编码读的，写中文会乱码；真正的提示文字由 `.ps1` 输出，那是 UTF-8 带 BOM 的。

---

## 首次准备

两台电脑都需要安装 Git for Windows，并使用 Git 克隆仓库。下载 ZIP 得到的文件夹没有 Git 历史和远端配置，无法运行同步。

在终端中执行，进入你希望存放仓库的目录后运行：

```powershell
git clone https://github.com/LonglongStarry-web/mc-coop-world.git
cd mc-coop-world
```

首次提交还需要设置提交署名，在仓库目录执行，替换为自己的姓名和邮箱：

```powershell
git config user.name "你的名字"
git config user.email "你的邮箱"
```

第一次推送时按 Git Credential Manager 的提示登录有写入权限的 GitHub 账号。

### 第 0 步：告诉脚本你的游戏装在哪

把 `game-dir.sample.txt` 复制一份、改名成 `game-dir.txt`，里面填写游戏实际使用的目录，即 saves 文件夹的上一级。

```
E:\HMCL\HMCL3.9.1\.minecraft
```

- 官方启动器一般是 `C:\Users\你的用户名\AppData\Roaming\.minecraft`，那就写这个；
- 用 HMCL / PCL 这类启动器，游戏目录经常被改到别处，去启动器设置里看「游戏目录」那一栏；
- 不填这行会默认用 `%APPDATA%\.minecraft`。请核对启动器实际使用的游戏目录，开启版本隔离时填写该版本的目录。pull 会创建缺少的目录，因此填错路径也可能成功复制，但游戏里看不到存档。配置文件请保存为 UTF-8。

`game-dir.txt` 不会被提交到仓库（已写进 `.gitignore`），所以你和朋友各自的路径互不干扰。

**这一步不做，后面全都白搭**，因为脚本找不到存档就等于没存档。

### 第 1 步：把存档传上去

其实不用手动放文件，跑一次 `push.bat`，脚本问你选哪个世界，然后自动把那个世界文件夹的内容复制进 `world/` 再提交。

想手动放也行，注意**不要把世界文件夹整个套进去**，要的是里面的内容：

```
world\level.dat        ✅ 正确
world\region\r.0.0.mca ✅ 正确
world\新的世界\level.dat ❌ 多套了一层，脚本会当成空存档
```

### 第 2 步：确认游戏版本

仓库当前存档记录的游戏版本为 Java 版 1.21.10。两边使用一致的游戏版本。脚本只传存档；如果使用模组，请自行保持两边加载器和所需模组兼容。

---

## 日常同步（Windows）

玩之前退出目标世界，再双击 pull.bat。脚本会从 GitHub 获取进度，仅允许快进更新，备份本地世界后导入到游戏目录。之后直接进游戏。

玩完退出世界，再双击 push.bat，查看文件变化预览并确认。脚本会把游戏存档同步到仓库并提交、推送。

已有旧版仓库的用户，需要先在仓库目录执行一次 git pull --ff-only，取得新版脚本。此后双击 pull.bat 就能完成更新和导入。

命令行等价写法（世界名不填会自动让你选）：

```powershell
# 拉取：玩之前，把朋友的进度拿下来
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull

# 推送：玩完之后，把自己的进度交上去
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push

# 推送并跳过确认（要挂到别的自动化里时用）
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Yes
```

同步时会检查网络和远端进度，网络失败会停止。远端有新提交时，push 会在复制前停止。请先备份你当前正在玩的进度，再决定采用哪一份存档，避免覆盖需要保留的内容。

push 在复制前显示 Robocopy 文件变化预览，其中 New File 为新增文件，Newer 等标记表示文件变化，EXTRA 表示目标中多出的文件。确认后两端目录会保持一致，包括同步删除。取消操作会直接退出。

如果提交已经成功、推送因网络或权限失败，提交会保留在本地。处理网络或权限问题后，再次双击 push.bat 即可重试，无需再修改存档。

pull 前会把本地世界备份到同级的 `<世界名>.bak-<时间>-<编号>` 文件夹。备份失败会停止导入。恢复时先退出世界，将当前世界另存，再把备份文件夹改回原世界名。备份不会自动删除，会占用本地磁盘空间，可确认无需恢复后自行清理。选择世界时会排除这些备份。

存档导入到 `<游戏目录>\saves\<所选世界名>\`，完成后会打印完整路径。没有本地世界时可以新建；同时存在多个世界时按提示选择，也可以用 -WorldName 指定专门的世界文件夹。导入前请确认目标世界。

同一个仓库同时运行多个同步窗口时会停止后启动的操作。游戏占用 session.lock 时也会停止，请先退出世界。

手动复制时，下面的 /E 仅新增和覆盖文件，删除不会同步。日常交接建议使用上述脚本。手动复制前也需要先更新仓库，并备份目标存档。

```bash
# 拉取（仓库 → 本地）
robocopy world "%APPDATA%\.minecraft\saves\我的世界" /E /XF .gitkeep README.md

# 推送（本地 → 仓库），然后照常 git add / commit / push
robocopy "%APPDATA%\.minecraft\saves\我的世界" world /E
```

---

## 上传量与仓库体积

第一次上传需要传完整存档。后续推送会复用远端已有的内容，传输新增或变化的数据，Git 还可能对相似版本进行差异压缩。实际上传量取决于改动和压缩效果，不能保证每次只有几 MB。

推送输出中的 Writing objects 及 MiB 数字可用于查看本次传输包大小。Robocopy 预览显示的是文件大小，两者可能相差很多。

Git 会保留历史版本，仓库体积会随游玩和提交增长。即使当前世界大小不变，历史占用也会增加。GitHub 建议仓库理想情况下小于 1 GB，强烈建议小于 5 GB；普通 Git 的单文件上限为 100 MiB。超过 1 GB 时应关注增长和同步耗时。

参考 [GitHub 容量说明](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github) 和 [Git 差异压缩说明](https://git-scm.com/book/en/v2/Git-Internals-Packfiles)。

---

## 玩历史存档

在仓库目录查看存档提交记录：

```powershell
git log --oneline -- world
```

将下面的“提交编号”替换为选中的编号，导出那一版世界：

```powershell
git archive --format=zip --output=../world-history.zip 提交编号 world/
```

压缩包位于仓库上一级目录。解压后将里面的 world 文件夹改名，例如“世界-旧进度”，放到游戏目录的 saves 文件夹。确认 level.dat 直接位于 saves\世界-旧进度\ 下，然后进游戏选择它。重复导出时请使用不同的压缩包文件名，以保留前次导出。

历史提交需要仍然保留。下面的压平历史操作会移除旧提交，操作前先将需要的旧版世界保存到仓库外。

---

## 关于 push：不需要找我，你自己就能推

推是**在你自己的电脑上、用你自己的 GitHub 账号**完成的，跟我没关系。我这边只在最开始帮你把仓库建起来、把代码传上去一次，之后你双击 `push.bat` 就行。

第一次 push 时 Windows 会弹一个 Git Credential Manager 的窗口让你登录 GitHub（浏览器授权一下），证书会存进系统凭据管理器，之后就不再问了。

朋友那边也一样：clone 公开仓库不用登录，但**他要 push 就必须用他自己的账号登录一次**，否则没有写权限。

判断标准很简单：**仓库里出现一个新提交，就等于推成功了。** 忘了推没推，打开网页看提交记录也行，或者直接再跑一次 `push.bat` —— 没有新变化时不会产生空提交，已有的待推送提交仍会被发送。

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

探索范围增加和历史累积都会扩大仓库。定期检查同步耗时和历史占用，按需要归档。

### 按需要整理历史

下面的方法会把历史压成一个提交，仅保留最新存档。操作前先将需要的历史版本导出到仓库外，并与朋友约定暂停同步。远端空间实际回收取决于 GitHub 的清理时机。

```bash
# 1. 先确保工作区干净，该推的都推了
git status

# 2. 造一个没有父提交的新分支，内容和当前完全一样
git checkout --orphan tmp-snapshot
git commit -m "snapshot: 压平历史"

# 3. 用它顶掉 main
git branch -D main
git branch -m main

# 4. 强推（会覆盖远端历史）
git push --force origin main

# 5. 本地清掉旧对象
git reflog expire --expire=now --all
git gc --prune=now --aggressive
```

做完之后，**朋友那边必须重新 clone，或者执行一次 `git fetch && git reset --hard origin/main`**，否则他一 push 就会把旧历史又带回来。

### 其他选择

1. **定期开新存档**，老存档打成压缩包单独放，仓库里只留新的。
2. **Git LFS** 可管理大文件，容量和流量计费请查看 GitHub 当时的套餐与账单说明，迁移前先评估历史版本的占用。

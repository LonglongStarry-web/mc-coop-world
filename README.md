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

| 路径 | 放什么 |
| --- | --- |
| `world/` | 存档。就是 `.minecraft\saves\` 下面那个世界文件夹的**整个内容** |
| `mods/` | 模组 `.jar`。方案 B 时服务端的 `mods/` 也用这份 |
| `game-dir.sample.txt` | 游戏目录的模板，复制改名成 `game-dir.txt` 填自己的路径 |
| `scripts/sync.ps1` | 同步脚本本体（PowerShell） |
| `pull.bat` | 双击 = 拉取存档 |
| `push.bat` | 双击 = 推送存档 |

`pull.bat` / `push.bat` 里只有一行调用，内容故意写成纯英文——`.bat` 是 cmd 按系统 OEM 编码读的，写中文会乱码；真正的提示文字由 `.ps1` 输出，那是 UTF-8 带 BOM 的。

---

## 首次准备

### 第 0 步：告诉脚本你的游戏装在哪

把 `game-dir.sample.txt` 复制一份、改名成 `game-dir.txt`，里面只写一行：**包含 `saves`、`mods`、`versions` 的那一层文件夹**。

```
E:\HMCL\HMCL3.9.1\.minecraft
```

- 官方启动器一般是 `C:\Users\你的用户名\AppData\Roaming\.minecraft`，那就写这个；
- 用 HMCL / PCL 这类启动器，游戏目录经常被改到别处，去启动器设置里看「游戏目录」那一栏；
- 不填这行会默认用 `%APPDATA%\.minecraft`，填错了脚本会直接报「找不到存档目录」，不会乱动你的东西。

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

### 第 2 步：模组丢进 `mods/`

两边的模组列表必须一模一样。

---

## 日常同步（Windows）

最省事：**双击 `pull.bat` 拉取，双击 `push.bat` 推送**，按提示选世界就行。

命令行等价写法（世界名不填会自动让你选）：

```powershell
# 拉取：玩之前，把朋友的进度拿下来
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull

# 推送：玩完之后，把自己的进度交上去
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push

# 推送并跳过确认（要挂到别的自动化里时用）
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Yes
```

脚本在 push 时会做四件事，中途会停下来等你确认：

```
[1/4] 检查远端有没有新进度   ← 朋友推过东西，这里直接拦下，不让你白推
[2/4] 把本地存档复制进仓库 world/
[3/4] 对比差异               ← 列出这次改了哪些文件、各多大、合计多少
      确认推送？(Y/n)
[4/4] 提交并推送
```

`pull` 前也会先把本地存档整份备份成 `<世界名>.bak-年月日-时分秒`，搞坏了改回原名就回退。

不想用脚本的话，手动也只要两条命令：

```bash
# 拉取（仓库 → 本地）
robocopy world "%APPDATA%\.minecraft\saves\我的世界" /E /XF .gitkeep README.md

# 推送（本地 → 仓库），然后照常 git add / commit / push
robocopy "%APPDATA%\.minecraft\saves\我的世界" world /E
```

---

## 关于流量：不会每次都传 0.5 G

Git 是按**文件内容哈希**管理的，不是整包上传：

- **没动过的文件，一个字节都不发。** 0.5 G 的存档里你这次只挖了一小块，剩下 99% 的文件哈希没变，Git 在握手阶段就跳过了。
- **改过的文件，发的是增量（delta），不是整个文件。** 一个 3 MB 的 `.mca` 只改了几十个区块，实际传输往往只有几百 KB。
- 所以一次正常 push 的真实流量，通常是**几 MB 到几十 MB**，跟你想象的不是一个量级。

推送时 Git 自己会打印实际传输量，形如 `Writing objects: 100% (12/12), 3.42 MiB` —— 那个数字才是这次真正上传的字节数。

但有一件事要注意：**仓库体积会随历史累积**。每次改动 Git 都会在历史里留一份新的 `.mca`，虽然打包时做过压缩，几个月下来仓库还是可能涨到 1 G 以上。想瘦身见文末「定期瘦身」。

---

## 关于 push：不需要找我，你自己就能推

推是**在你自己的电脑上、用你自己的 GitHub 账号**完成的，跟我没关系。我这边只在最开始帮你把仓库建起来、把代码传上去一次，之后你双击 `push.bat` 就行。

第一次 push 时 Windows 会弹一个 Git Credential Manager 的窗口让你登录 GitHub（浏览器授权一下），证书会存进系统凭据管理器，之后就不再问了。

朋友那边也一样：clone 公开仓库不用登录，但**他要 push 就必须用他自己的账号登录一次**，否则没有写权限。

判断标准很简单：**仓库里出现一个新提交，就等于推成功了。** 忘了推没推，打开网页看提交记录也行，或者直接再跑一次 `push.bat` —— 脚本会告诉你「存档和仓库里完全一致，没有需要推送的内容」，不会产生空提交。

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

GitHub 单文件上限 100 MB，仓库建议控制在 1 GB 以内。探索范围很大的世界，加上每天累积的历史，是可能超的。

### 定期瘦身（推荐每玩 1～2 个月做一次）

思路是**把历史压成一个提交**，只留最新一版存档。老版本会被丢弃，仓库体积能掉回去一大截。

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
2. **Git LFS**：`git lfs track "world/*.mca"`，但免费额度只有 1 GB 存储 + 1 GB/月流量，玩得勤反而不够。

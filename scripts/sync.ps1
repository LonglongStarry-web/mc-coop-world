<#
.SYNOPSIS
    在本机 Minecraft 存档和本仓库的 world/ 目录之间同步。

.DESCRIPTION
    pull  仓库 world/  ->  本机 .minecraft\saves\<世界名>
          覆盖前会把本地存档整份备份一份，搞坏了能回退。

    push  本机存档  ->  仓库 world/
          只推送你在列表里选中的那一个世界，不会再自己挑。

    世界选择：
      每次运行都会列出 saves 目录里的世界，按最后游玩时间从新到旧排序，
      标出每个世界的文件夹名、修改时间和体积。输入序号选定。
      直接回车 = 上次同步过的那个世界（记在 .sync-state.json 里）。
      输入 q 取消。

    push 会先列出这次到底改了哪些文件、多大，你确认之后才提交和推送。
    不想确认就加 -Yes（此时自动采用上次同步的世界）。

    分段推送：一次改动很大时（比如连续玩了两天），单个推送包可能有上百 MB，
    这种大包很容易被网络中途重置。所以 push 会把改动按体积切成若干段
    （默认每段约 64 MB），提交一段、推一段。断在某一段时，前面几段已经在云端，
    下次再跑 push 会从断掉的地方接着推。-SegmentMB 可调整每段大小，0 = 不分段。

    pull 会先更新 Git 仓库，再备份并完整同步本地世界。
    两边的存档目录会保持一致，包括同步文件删除。

    网络：到 GitHub 的直连经常时通时不通（Failed to connect to github.com
    port 443）。每次网络操作前会先探测直连，不通就自动借用本机正在运行的
    代理（10808 / 7890 等），两条路都带重试。代理只对本次 git 命令生效，
    不改 git 全局配置；也可以用 -Proxy 手动指定。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Yes

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -WorldName "新的世界 (2)"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -SegmentMB 32

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Proxy http://127.0.0.1:10808
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('pull', 'push')]
    [string]$Mode,

    # 世界文件夹名（要写 saves 下的真实文件夹名，不是游戏里显示的名字）。
    # 不填就列出存档目录让你选。
    [string]$WorldName,

    # 游戏目录（里面要有 saves 那一层）。不填就读仓库根目录的 game-dir.txt，
    # 再不行才退回默认的 %APPDATA%\.minecraft。
    [string]$GameDir,

    # 直接指定存档目录，优先级最高，一般只有测试时才用
    [string]$SavesDir,

    # push 时跳过确认和选择，直接提交推送
    [switch]$Yes,

    # 网络操作（检查远端、推送）失败后自动重试的次数，默认 3
    [ValidateRange(1, 10)]
    [int]$PushRetries = 3,

    # 手动指定代理，例如 http://127.0.0.1:10808 或 socks5h://127.0.0.1:10808。
    # 不填时脚本会自动探测本机正在运行的代理（v2rayN / Clash 等）。
    [string]$Proxy,

    # 分段推送：每段大约多少 MB。一次推几百 MB 容易被网络掐断，
    # 分成几十 MB 一段、推完一段再推下一段成功率高很多。0 表示不分段。
    [ValidateRange(0, 1024)]
    [double]$SegmentMB = 64
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$repoWorld = Join-Path $repoRoot 'world'

# ---------------------------------------------------------------- 定位游戏目录

if (-not $SavesDir) {

    if (-not $GameDir) {
        $cfg = Join-Path $repoRoot 'game-dir.txt'
        if (Test-Path -LiteralPath $cfg) {
            $line = Get-Content -LiteralPath $cfg -Encoding UTF8 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                    Select-Object -First 1
            if ($line) { $GameDir = $line.Trim() }
        }
    }

    if (-not $GameDir) { $GameDir = Join-Path $env:APPDATA '.minecraft' }

    $SavesDir = Join-Path $GameDir 'saves'
}

$SavesDir = [IO.Path]::GetFullPath($SavesDir)

# 记住上次同步的是哪个世界，下次默认就选它。
$stateFile = Join-Path $repoRoot '.sync-state.json'

# ---------------------------------------------------------------- 小工具

function Invoke-Robocopy {
    param([string]$Source, [string]$Dest, [switch]$Preview, [switch]$Backup)

    if (-not $Preview -and -not (Test-Path -LiteralPath $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }

    # 备份只复制，正式同步使用 /MIR，使源中已删除的文件不会留在目标里。
    # 排除正在持有的游戏锁、旧元数据备份和仓库占位文件。
    $options = @('/MIR', '/R:2', '/W:1', '/XF', '.gitkeep', 'README.md', 'session.lock', 'level.dat_old',
                 '/NDL', '/NJH', '/NJS', '/NP')
    if ($Backup) { $options[0] = '/E' }
    if ($Preview) {
        & robocopy $Source $Dest @options /L /BYTES /FP
    }
    else {
        & robocopy $Source $Dest @options /NFL | Out-Null
    }
    $code = $LASTEXITCODE

    # robocopy 退出码 0-7 都算正常，>=8 才是真失败
    if ($code -ge 8) { throw "robocopy 失败，退出码 $code" }
}

function Invoke-Git {
    param([string[]]$Arguments)
    $result = & git -C $repoRoot @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git 操作失败：git $($Arguments -join ' ')。请处理上面的错误后重试。" }
    return $result
}

# ---------------------------------------------------------------- 网络自适应
#
# 到 GitHub 的直连经常是「时通时不通」：刚才还 200，一会儿就
#   fatal: unable to access ...: Failed to connect to github.com port 443 after 21110 ms
# 这种和存档、账号权限都没关系，原样重试同一个直连也没用。网络操作统一走
# Invoke-GitNetwork：先花几秒探测直连，通就走直连；不通就自动借本机已经开着的
# 代理（v2rayN 的 10808、Clash 的 7890 等）再试。代理只用 -c http.proxy=... 对这个
# 进程生效，不改你的 git 全局配置。

# 探测本机端口有没有在监听（异步 + 超时，连不上也不会卡住）
function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000)

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch { return $false }
    finally { if ($client) { $client.Close() } }
}

# 从 remote 地址里取主机名，用来判断连通性
function Get-RemoteUrl {
    try {
        $u = (& git -C $repoRoot remote get-url origin 2>$null)
        if ($u) { return ([string]$u).Trim() }
    }
    catch { }
    return $null
}

function Get-RemoteHost {
    $url = Get-RemoteUrl
    if (-not $url) { return 'github.com' }

    if ($url -match '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+)') { return $Matches[1] }
    if ($url -match '^[\w\.-]+@([^:]+):') { return $Matches[1] }
    return 'github.com'
}

# 远端是磁盘路径或 file:// 时（本地裸仓库、局域网共享），不经过网络，别去探测代理
function Test-RemoteIsLocal {
    $url = Get-RemoteUrl
    if (-not $url) { return $false }
    if ($url -match '^file://') { return $true }
    if ($url -match '://') { return $false }
    if ($url -match '^[^\s@/\\]+@[^:]+:') { return $false }   # git@host:path 这种 SSH 地址
    return $true
}

# 可尝试的代理：先看配置和环境变量，再看常见客户端在跑的本地端口
function Get-ProxyCandidates {
    $raw = @()
    if ($Proxy) { $raw += $Proxy }
    foreach ($v in @($env:HTTPS_PROXY, $env:https_proxy, $env:HTTP_PROXY, $env:http_proxy)) {
        if ($v) { $raw += $v }
    }
    foreach ($scope in @('--local', '--global')) {
        try {
            $cfg = (& git -C $repoRoot config $scope http.proxy 2>$null)
            if ($cfg) { $raw += $cfg }
        }
        catch { }
    }

    $result = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in $raw) {
        if (-not $r) { continue }
        $u = ([string]$r).Trim()
        if (-not $u) { continue }
        if ($u -notmatch '://') { $u = "http://$u" }
        if ($seen.ContainsKey($u)) { continue }
        $seen[$u] = $true
        [void]$result.Add([pscustomobject]@{ Url = $u })
    }

    # 常见本地端口：10808/1080 多半是 SOCKS，两种协议都排进去
    $ports = @(
        @{ Port = 10809; Scheme = 'http' },     # v2rayN 的 HTTP 端口
        @{ Port = 7890; Scheme = 'http' },      # Clash
        @{ Port = 7897; Scheme = 'http' },      # Clash Verge
        @{ Port = 1080; Scheme = 'socks5h' },   # 通用 SOCKS
        @{ Port = 10808; Scheme = 'http' },     # v2rayN 的 SOCKS 端口，也常兼容 HTTP
        @{ Port = 10808; Scheme = 'socks5h' }
    )
    foreach ($p in $ports) {
        $port = [int]$p.Port
        if (-not (Test-TcpPort -TargetHost '127.0.0.1' -Port $port -TimeoutMs 400)) { continue }
        $u = "$($p.Scheme)://127.0.0.1:$port"
        if ($seen.ContainsKey($u)) { continue }
        $seen[$u] = $true
        [void]$result.Add([pscustomobject]@{ Url = $u })
    }

    return $result
}

# 判断失败是「连不上」还是「被拒绝」（权限、非快进、冲突）
function Test-NetworkError {
    param([string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match 'Failed to connect' -or
            $Text -match 'Could not connect to server' -or
            $Text -match 'Could not resolve host' -or
            $Text -match 'Connection was reset' -or
            $Text -match 'Connection reset by peer' -or
            $Text -match 'Connection timed out' -or
            $Text -match 'Operation timed out' -or
            $Text -match 'timed out' -or
            $Text -match 'RPC failed' -or
            $Text -match 'remote end hung up' -or
            $Text -match 'unexpected disconnect' -or
            $Text -match 'curl (5[5-9]|7|28|35|52)')
}

# 跑一条 git 命令，边跑边把输出打出来（大包上传的进度要看得见），同时收集文本
function Invoke-GitCapture {
    param([string[]]$Arguments, [switch]$Quiet)

    $lines = New-Object System.Collections.ArrayList
    $prevEap = $ErrorActionPreference
    # 原生命令的 stderr 在 PS 5.1 里会变成 ErrorRecord，EAP=Stop 时可能直接把脚本打断
    $ErrorActionPreference = 'Continue'
    try {
        & git @Arguments 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
            [void]$lines.Add($line)
            if (-not $Quiet) { Write-Host $line }
        }
    }
    finally { $ErrorActionPreference = $prevEap }

    return @{ Code = $LASTEXITCODE; Lines = $lines }
}

# 统一入口：探测直连 -> 失败换本机代理 -> 每次尝试都可重试
function Invoke-GitNetwork {
    param(
        [string[]]$Arguments,
        [int]$Attempts = 3,
        [switch]$Quiet
    )

    # 本地路径 / file:// 远端不经过网络，直接跑
    if (Test-RemoteIsLocal) {
        $r = Invoke-GitCapture -Arguments (@('-C', $repoRoot) + $Arguments) -Quiet:$Quiet
        return @{ Ok = ($r.Code -eq 0); Network = $false; Proxy = $null; Lines = $r.Lines; Text = ($r.Lines -join "`n") }
    }

    $hostName = Get-RemoteHost
    $directOk = Test-TcpPort -TargetHost $hostName -Port 443 -TimeoutMs 4000

    $plan = New-Object System.Collections.ArrayList
    if ($directOk) { [void]$plan.Add([pscustomobject]@{ Label = '直连'; Proxy = $null }) }
    foreach ($p in (Get-ProxyCandidates)) {
        [void]$plan.Add([pscustomobject]@{ Label = $p.Url; Proxy = $p.Url })
    }

    if ($plan.Count -eq 0) {
        return @{ Ok = $false; Network = $true; Proxy = $null; Lines = @()
            Text = "连不上 $hostName，也没有找到可用的本机代理。" }
    }

    if (-not $directOk) {
        Write-Host ("  直连 {0} 不通（443 端口连不上），改试本机代理。" -f $hostName) -ForegroundColor Yellow
    }

    $lastText = ''
    for ($n = 0; $n -lt $plan.Count; $n++) {
        $node = $plan[$n]

        for ($i = 1; $i -le $Attempts; $i++) {
            if ($n -gt 0 -and $i -eq 1) {
                Write-Host ("  改走 {0} 再试…" -f $node.Label) -ForegroundColor Cyan
            }
            elseif ($i -gt 1) {
                Write-Host ("  第 {0}/{1} 次重试（{2}）…" -f $i, $Attempts, $node.Label) -ForegroundColor Cyan
            }

            $gargs = @('-C', $repoRoot)
            if ($node.Proxy) { $gargs += @('-c', "http.proxy=$($node.Proxy)") }
            $gargs += $Arguments

            $r = Invoke-GitCapture -Arguments $gargs -Quiet:$Quiet
            if ($r.Code -eq 0) {
                if ($node.Proxy) {
                    Write-Host ("  这次是通过本机代理 {0} 连上的。" -f $node.Label) -ForegroundColor DarkGray
                }
                return @{ Ok = $true; Network = $false; Proxy = $node.Proxy; Lines = $r.Lines; Text = '' }
            }

            $lastText = ($r.Lines -join "`n")
            if (-not (Test-NetworkError -Text $lastText)) {
                # 不是网络问题（权限、非快进、冲突…），换通路也没用，交回调用方
                return @{ Ok = $false; Network = $false; Proxy = $node.Proxy; Lines = $r.Lines; Text = $lastText }
            }

            if ($i -lt $Attempts) {
                $wait = 4 * $i
                Write-Host ("  连不上，{0} 秒后重试。" -f $wait) -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            }
        }

        if ($n -lt $plan.Count - 1) {
            Write-Host '  这条路还是不通，换下一条通路。' -ForegroundColor Yellow
        }
    }

    return @{ Ok = $false; Network = $true; Proxy = $null; Lines = @(); Text = $lastText }
}

function Show-NetworkFailHelp {
    param([string]$Reason)

    Write-Host ''
    if ($Reason) { Write-Host $Reason -ForegroundColor Red }
    Write-Host '连不上 GitHub：这是本机到 github.com 的网络问题，' -ForegroundColor Red
    Write-Host '和存档、账号权限都没有关系。' -ForegroundColor Red
    Write-Host '存档和本地提交都还在，什么都没丢。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '可以这样排查：' -ForegroundColor Yellow
    Write-Host ' 1. 浏览器打开 https://github.com，看能不能进。' -ForegroundColor Yellow
    Write-Host '    进不去就说明网络被拦了或者断了。' -ForegroundColor Yellow
    Write-Host ' 2. 代理软件要确认正在运行。脚本会自动借用' -ForegroundColor Yellow
    Write-Host '    10808 / 7890 这类本地端口；也可以手动指定：' -ForegroundColor Yellow
    Write-Host '    push.bat -Proxy http://127.0.0.1:10808' -ForegroundColor Yellow
    Write-Host ' 3. 换个网络试试，手机热点通常比某些宽带稳。' -ForegroundColor Yellow
    Write-Host ' 4. 一直不行就改用 SSH（走 443 端口，比 22 容易通）：' -ForegroundColor Yellow
    Write-Host '    git remote set-url origin git@github.com:LonglongStarry-web/mc-coop-world.git' -ForegroundColor Yellow
    Write-Host '    需要先在 GitHub 里配好 SSH 公钥，见使用指南。' -ForegroundColor Yellow
}

# 存档一次动辄上百 MB，一次性推大包很容易被中间网络重置
# （curl 55 / RPC failed; Connection was reset / the remote end hung up）。
# 这里负责：调本仓库的 HTTP 设置、失败重试、必要时换本机代理，
# 最后再核对一次远端，避免「其实已经送到了」被当成失败重传一遍。
# 返回 $true 表示远端确实收到了本地 HEAD。
function Invoke-PushWithRetry {
    param([int]$Attempts = 3)

    & git -C $repoRoot config http.postBuffer 524288000 | Out-Null
    & git -C $repoRoot config http.version HTTP/1.1 | Out-Null

    $branch = (& git -C $repoRoot branch --show-current)
    if ($branch) { $branch = $branch.Trim() }
    $head = (& git -C $repoRoot rev-parse HEAD)
    if ($head) { $head = $head.Trim() }

    $r = Invoke-GitNetwork -Arguments @('push') -Attempts $Attempts
    if ($r.Ok) { return $true }

    # 被远端拒绝（权限、非快进、仓库规则）不是网络问题，把 git 的原话留下，别吞掉真正的原因
    if (-not $r.Network) {
        Write-Host ''
        Write-Host '推送被远端拒绝了（不是网络问题）。下面是 git 的原话：' -ForegroundColor Red
        if ($r.Text) { Write-Host $r.Text -ForegroundColor Yellow }
        return $false
    }

    # 全部失败后再核对一次远端：可能包已经送到，只是回执阶段被掐断，避免白重传。
    if ($branch -and $head) {
        $check = Invoke-GitNetwork -Arguments @('ls-remote', 'origin', "refs/heads/$branch") -Attempts 1 -Quiet
        if ($check.Ok) {
            $remoteSha = $null
            foreach ($l in $check.Lines) {
                if ($l -match '^([0-9a-f]{40})\s') { $remoteSha = $Matches[1]; break }
            }
            if ($remoteSha -eq $head) {
                Write-Host '连接报了错，但远端已经收到这次提交，按成功处理。' -ForegroundColor Yellow
                return $true
            }
        }
    }

    return $false
}

# 列出 world/ 下相对当前提交改动过的文件，带体积，用于分批推送。
function Get-ChangedWorldPaths {
    $raw = Invoke-Git -Arguments @('-c', 'status.renames=false', 'status', '--porcelain', '-uall', '-z', '--', 'world')
    $text = ($raw -join '')
    $items = @()
    foreach ($rec in ($text -split "`0")) {
        if (-not $rec -or $rec.Length -le 3) { continue }
        $rel = $rec.Substring(3)
        $full = Join-Path $repoRoot ($rel -replace '/', '\')
        $size = 0
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $size = (Get-Item -LiteralPath $full).Length
        }
        $items += [pscustomobject]@{ Path = $rel; Size = [double]$size }
    }
    return $items
}

# 按体积和文件数把改动切成若干段，避免单次推送的包过大。
function Split-WorldChanges {
    param([object[]]$Items, [double]$LimitBytes)

    $batches = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    $curSize = 0.0

    foreach ($it in $Items) {
        # 单批不超过 40 个文件，免得命令行过长
        if ($cur.Count -gt 0 -and (($curSize + $it.Size) -gt $LimitBytes -or $cur.Count -ge 40)) {
            [void]$batches.Add(@($cur))
            $cur.Clear()
            $curSize = 0.0
        }
        [void]$cur.Add($it)
        $curSize += $it.Size
    }
    if ($cur.Count -gt 0) { [void]$batches.Add(@($cur)) }
    return $batches
}

function Show-PushFailHelp {
    param([string]$Stage)

    Write-Host ''
    if ($Stage) { Write-Host $Stage -ForegroundColor Red }
    else { Write-Host '推送没成功：连接被重置，或者没有推送权限，远端还是旧进度。' -ForegroundColor Red }
    Write-Host @'
你的提交已经存在本地，存档也已经复制进仓库了，不需要重新选世界或重新复制。
等网络好一些，直接再双击 push.bat 就行，它会接着把还没推上去的部分传上去。

如果一直失败，可以试：
  1. 核对登录的 GitHub 账号有没有这个仓库的写权限（协作者邀请要点接受）；
  2. 换网络（手机热点通常比某些宽带稳），或者挂上代理再推；
  3. 改用 SSH 方式，通常比 HTTPS 稳（尤其是大文件上传总被重置时）：
     git remote set-url origin git@github.com:LonglongStarry-web/mc-coop-world.git
     需要先在 GitHub 里配置好 SSH 公钥，配置方法见使用指南。
'@ -ForegroundColor Yellow
}

function Assert-World {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'level.dat') -PathType Leaf)) {
        throw "没有找到 level.dat，无法同步这个世界：$Path"
    }
}

function Assert-NoLinks {
    param([string]$Path)
    # 镜像同步不能沿目录链接删除或覆盖世界目录之外的文件。
    $parent = [IO.DirectoryInfo]::new($Path)
    while ($parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "存档路径包含目录链接，请改用实际目录：$($parent.FullName)"
        }
        $parent = $parent.Parent
    }
    if (Test-Path -LiteralPath $Path) {
        $links = Get-ChildItem -LiteralPath $Path -Recurse -Force |
                 Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                 Select-Object -First 1
        if ($links) { throw "存档中存在文件或目录链接，无法镜像同步：$($links.FullName)" }
    }
}

# ---------------------------------------------------------------- 世界选择

# 名字去掉结尾的 " (2)" " (3)" 这类副本后缀，用来识别同名副本
function Get-WorldKey {
    param([string]$Name)
    return ($Name -replace '\s*\(\d+\)\s*$', '').Trim()
}

function Get-SavedWorlds {
    param([string]$Saves)
    if (-not (Test-Path -LiteralPath $Saves)) { return @() }
    return @(Get-ChildItem -LiteralPath $Saves -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike '*.bak-*' } |
             Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') })
}

function Get-WorldInfo {
    param([string]$Path)
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    # 用 level.dat 的修改时间当「最后游玩时间」，比文件夹时间准
    $stamp = $null
    $level = Join-Path $Path 'level.dat'
    if (Test-Path -LiteralPath $level) { $stamp = (Get-Item -LiteralPath $level).LastWriteTime }
    if (-not $stamp) { $stamp = (Get-Item -LiteralPath $Path).LastWriteTime }
    return [pscustomobject]@{ Bytes = [double]$bytes; Time = $stamp }
}

function Get-SyncState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch { return $null }
}

function Save-SyncState {
    param([string]$World, [string]$Saves)
    $data = [ordered]@{
        world   = $World
        saves   = $Saves
        updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    try {
        [IO.File]::WriteAllText($stateFile, ($data | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        # 记不住不影响同步，只是下次要手动选
        Write-Host "（提示：没能写入 $stateFile，下次请手动选世界）" -ForegroundColor DarkGray
    }
}

function Get-LastSyncedWorld {
    $state = Get-SyncState
    if (-not $state) { return $null }
    if (-not $state.world) { return $null }
    # 换了存档目录（比如换了启动器）时，旧记录不算数
    if ($state.saves -and ($state.saves -ne $SavesDir)) { return $null }
    return [string]$state.world
}

function Select-World {
    param(
        [string]$Name,
        [string]$Saves,
        [switch]$AllowNew,
        [switch]$NoPrompt
    )

    if ($Name) {
        $path = Join-Path $Saves $Name
        if (-not (Test-Path -LiteralPath $path) -and -not $AllowNew) {
            throw "找不到存档目录：$path"
        }
        return $Name
    }

    if (-not (Test-Path -LiteralPath $Saves)) {
        if ($AllowNew) { New-Item -ItemType Directory -Path $Saves -Force | Out-Null }
        else { throw "找不到 Minecraft 存档目录：$Saves" }
    }

    $worlds = @(Get-SavedWorlds -Saves $Saves)

    if ($worlds.Count -eq 0) {
        # 全新机器，本地一个世界都没有：让他自己起个名字，pull 会建成这个
        if (-not $AllowNew) { throw "这个目录下没有可用的世界：$Saves" }
        Write-Host '你本地还没有任何世界，这次会新建一个。' -ForegroundColor Cyan
        while ($true) {
            $newName = Read-Host '给这个存档起个名字（随便起，比如 双人世界）'
            if ($newName -and $newName.Trim()) { return $newName.Trim() }
            Write-Host '名字不能为空。' -ForegroundColor Yellow
        }
    }

    $rows = @()
    foreach ($w in $worlds) {
        $info = Get-WorldInfo -Path $w.FullName
        $rows += [pscustomobject]@{ Name = $w.Name; Time = $info.Time; MB = ($info.Bytes / 1MB) }
    }
    $rows = @($rows | Sort-Object -Property Time -Descending)

    # 统计同名副本，用于提示
    $keys = @{}
    foreach ($r in $rows) {
        $k = Get-WorldKey -Name $r.Name
        if (-not $keys.ContainsKey($k)) { $keys[$k] = 0 }
        $keys[$k] = $keys[$k] + 1
    }

    $lastWorld = Get-LastSyncedWorld
    $default = 1
    if ($lastWorld) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Name -eq $lastWorld) { $default = $i + 1; break }
        }
    }

    if ($Mode -eq 'push') {
        Write-Host '你 saves 目录里的世界（选中的那个会被推送到云端，覆盖云端存档）：' -ForegroundColor Cyan
    }
    else {
        Write-Host '你 saves 目录里的世界（选中的那个会被云端存档覆盖）：' -ForegroundColor Cyan
    }

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $isDefault = (($i + 1) -eq $default)
        $mark = '   '
        if ($isDefault) { $mark = ' → ' }
        $line = '  {0}[{1}]  {2}  {3,9:N1} MB  {4}' -f $mark, ($i + 1), $r.Time.ToString('yyyy-MM-dd HH:mm'), $r.MB, $r.Name

        $tags = @()
        if ($lastWorld -and $r.Name -eq $lastWorld) { $tags += '上次同步' }
        if ($keys[(Get-WorldKey -Name $r.Name)] -gt 1) { $tags += '同名副本' }
        if ($tags.Count) { $line = $line + '   (' + ($tags -join '、') + ')' }

        if ($isDefault) { Write-Host $line -ForegroundColor Green }
        else { Write-Host $line }
    }

    $dupKeys = @($keys.GetEnumerator() | Where-Object { $_.Value -gt 1 })
    if ($dupKeys.Count -gt 0) {
        Write-Host '注意：上面标了「同名副本」的世界，名字很像但文件夹不同，游戏里显示的名字也可能一样。' -ForegroundColor Yellow
        Write-Host '      请按「文件夹名」和「修改时间」确认哪个才是你现在在玩的，选错会推错存档。' -ForegroundColor Yellow
    }

    if ($NoPrompt) {
        $auto = $rows[$default - 1].Name
        Write-Host "自动选择：$auto" -ForegroundColor Green
        return $auto
    }

    $hint = "输入序号（回车 = $default"
    if ($AllowNew) { $hint = "$hint，n = 新建" }
    $hint = "$hint，q = 取消）"

    while ($true) {
        $pick = Read-Host $hint
        if ($null -eq $pick) { $pick = '' } else { $pick = $pick.Trim() }

        if ($pick -eq '') { return $rows[$default - 1].Name }

        if ($pick -in @('q', 'Q')) {
            Write-Host '已取消。' -ForegroundColor Yellow
            exit 0
        }

        if ($AllowNew -and ($pick -in @('n', 'N'))) {
            while ($true) {
                $newName = Read-Host '给这个新存档起个名字'
                if ($newName -and $newName.Trim()) { return $newName.Trim() }
                Write-Host '名字不能为空。' -ForegroundColor Yellow
            }
        }

        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $rows.Count) {
            return $rows[$n - 1].Name
        }
        Write-Host '输入无效，请输入列表里的序号。' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 选世界

$NoPrompt = $Yes.IsPresent -or [Console]::IsInputRedirected

Write-Host '[1/4] 选择存档'
$WorldName = Select-World -Name $WorldName -Saves $SavesDir -AllowNew:($Mode -eq 'pull') -NoPrompt:$NoPrompt

# 同时检查命令行参数和交互输入。
if ($WorldName -in @('.', '..') -or
    $WorldName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    $WorldName -ne $WorldName.Trim() -or $WorldName.EndsWith('.')) {
    throw '世界名必须是单个合法文件夹名，不能包含路径或上级目录。'
}
$localWorld = [IO.Path]::GetFullPath((Join-Path $SavesDir $WorldName))
$repoRoot = [IO.Path]::GetFullPath($repoRoot)
$repoWorld = Join-Path $repoRoot 'world'
if ($localWorld.StartsWith("$repoRoot\", [StringComparison]::OrdinalIgnoreCase) -or
    $repoRoot.StartsWith("$localWorld\", [StringComparison]::OrdinalIgnoreCase) -or
    $localWorld -eq $repoRoot) {
    throw '游戏存档和同步仓库必须使用分开的目录。'
}
Assert-NoLinks -Path $localWorld
Assert-NoLinks -Path $repoWorld

Write-Host "仓库：$repoRoot"
Write-Host "世界：$localWorld"
Write-Host ''

# ---------------------------------------------------------------- 主流程

# 防止两个同步窗口同时改同一仓库。
$gitTop = [IO.Path]::GetFullPath((Invoke-Git -Arguments @('rev-parse', '--show-toplevel')))
if ($gitTop -ne $repoRoot) { throw '请使用 git clone 得到的独立仓库目录，再运行脚本。' }
$gitDir = Invoke-Git -Arguments @('rev-parse', '--absolute-git-dir')
$syncLock = $null
$worldLock = $null
try {
    try {
        $syncLock = [IO.File]::Open((Join-Path $gitDir 'mc-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { throw '另一个同步正在运行，请等它结束再试。' }

    if (Test-Path -LiteralPath $localWorld -PathType Container) {
        try {
            $worldLock = [IO.File]::Open((Join-Path $localWorld 'session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        }
        catch { throw '存档正在使用或无法访问。请退出这个世界，再重新同步。' }
    }

    # 所有网络错误都停止，避免把旧仓库存档当作最新进度导入游戏。
    $upstream = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $remoteName = Invoke-Git -Arguments @('config', "branch.$(Invoke-Git -Arguments @('branch', '--show-current')).remote")
    Write-Host '[2/4] 检查远端进度'
    # 直连不通会自动换本机代理，并带重试
    $fetch = Invoke-GitNetwork -Arguments @('fetch', $remoteName) -Attempts $PushRetries -Quiet
    if (-not $fetch.Ok) {
        Show-NetworkFailHelp -Reason '拉取远端进度失败，本地存档没有被动过。'
        exit 1
    }
    $behind = [int](Invoke-Git -Arguments @('rev-list', '--count', "HEAD..$upstream"))
    $ahead = [int](Invoke-Git -Arguments @('rev-list', '--count', "$upstream..HEAD"))

    switch ($Mode) {
        'pull' {
            if ($ahead -gt 0) {
                throw '本地还有未推送的提交。请先运行 push.bat 交接本地进度，再拉取。'
            }
            # 只检查已跟踪文件的改动；仓库里多出来的杂项文件不该拦住拉取，
            # 真要覆盖它们时 git merge 自己会报错并停下。
            $dirty = Invoke-Git -Arguments @('status', '--porcelain', '--untracked-files=no')
            if ($dirty) { throw '仓库中有未提交的改动。请先提交或备份处理这些改动，再拉取。' }

            Invoke-Git -Arguments @('merge', '--ff-only', $upstream) | Out-Host
            # 更新仓库后再验证，支持远端首次加入存档，也防止误导入空目录。
            Assert-World -Path $repoWorld
            Assert-NoLinks -Path $repoWorld

            if (Test-Path -LiteralPath $localWorld) {
                $backup = "$localWorld.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
                Write-Host "[3/4] 备份本地存档 -> $backup"
                Invoke-Robocopy -Source $localWorld -Dest $backup -Backup
            }
            else {
                Write-Host '[3/4] 本地没有这个存档，直接新建'
                New-Item -ItemType Directory -Path $localWorld | Out-Null
                $worldLock = [IO.File]::Open((Join-Path $localWorld 'session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            }

            Write-Host '[4/4] 导入最新存档'
            Invoke-Robocopy -Source $repoWorld -Dest $localWorld
            Save-SyncState -World $WorldName -Saves $SavesDir
            Write-Host "完成。存档在：$localWorld" -ForegroundColor Green
            Write-Host "进游戏请选文件夹名为「$WorldName」的那个世界。" -ForegroundColor Green
        }

        'push' {
            Assert-World -Path $localWorld
            if ($behind -gt 0) {
                throw "远端有 $behind 个本地没有的提交。请先备份当前游戏存档，再拉取并确认采用哪份进度。"
            }

            # 和脚本记住的上次同步世界对比，用来发现「选错了世界」。
            # 不用 git log 里的中文提交信息判断，那会受控制台代码页影响变成乱码。
            $prevWorld = Get-LastSyncedWorld
            if ($prevWorld) {
                if ($prevWorld -ne $WorldName) {
                    Write-Host "上次同步的是「$prevWorld」，这次你选的是「$WorldName」。" -ForegroundColor Yellow
                    Write-Host '如果没打算换存档，说明选错了：这次推送会用本地这一份覆盖云端进度。' -ForegroundColor Yellow
                }
                else {
                    Write-Host "和上次同步的是同一个世界：$prevWorld" -ForegroundColor DarkGray
                }
            }

            # 先检查提交身份，避免复制后才发现 Git 尚未配置姓名和邮箱。
            Invoke-Git -Arguments @('var', 'GIT_AUTHOR_IDENT') | Out-Null
            Invoke-Git -Arguments @('var', 'GIT_COMMITTER_IDENT') | Out-Null
            Write-Host '[3/4] 预览存档变化（字节数为文件大小，传输量取决于 Git 压缩）'
            Invoke-Robocopy -Source $localWorld -Dest $repoWorld -Preview
            if (-not $Yes) {
                Write-Host '目标目录将与本地世界一致，包括删除目标中多出的存档文件。' -ForegroundColor Yellow
                $answer = Read-Host "确认用「$WorldName」同步并推送？(Y/n)"
                if ($answer -and $answer.Trim().ToLower() -notin @('', 'y', 'yes')) {
                    Write-Host '已取消。' -ForegroundColor Yellow
                    exit 0
                }
            }

            Invoke-Robocopy -Source $localWorld -Dest $repoWorld
            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
            $changes = @(Get-ChangedWorldPaths)
            $totalBytes = 0.0
            foreach ($c in $changes) { $totalBytes += $c.Size }

            Write-Host '[4/4] 提交并推送进度'

            if ($changes.Count -eq 0) {
                # 没有新改动，但本地可能还有上次没推上去的提交
                if (-not (Invoke-PushWithRetry -Attempts $PushRetries)) {
                    Show-PushFailHelp
                    exit 1
                }
            }
            else {
                # 一次传几百 MB 很容易被掐断，所以按体积切成若干段：每段提交一次就推一次，
                # 断在某一段时，前面几段已经在云端了，下次接着推剩下的部分。
                $limit = [double]::MaxValue
                if ($SegmentMB -gt 0) { $limit = $SegmentMB * 1MB }
                $batches = @(Split-WorldChanges -Items $changes -LimitBytes $limit)

                if ($batches.Count -gt 1) {
                    Write-Host ("这次改动 {0:N1} MB / {1} 个文件，分成 {2} 段逐步推送（每段约 {3:N0} MB）。" -f ($totalBytes / 1MB), $changes.Count, $batches.Count, $SegmentMB) -ForegroundColor Cyan
                    Write-Host '全部推完之前先别叫朋友 pull，他那边会拿到新旧混合的存档。' -ForegroundColor Yellow
                }

                for ($b = 0; $b -lt $batches.Count; $b++) {
                    $batch = @($batches[$b])
                    $paths = @($batch | ForEach-Object { $_.Path })
                    $batchBytes = 0.0
                    foreach ($f in $batch) { $batchBytes += $f.Size }

                    if ($batches.Count -gt 1) {
                        Write-Host ("  第 {0}/{1} 段：{2} 个文件，{3:N1} MB" -f ($b + 1), $batches.Count, $paths.Count, ($batchBytes / 1MB)) -ForegroundColor Cyan
                    }

                    Invoke-Git -Arguments (@('add', '--') + $paths) | Out-Null

                    $msg = "sync: $WorldName @ $stamp"
                    if ($batches.Count -gt 1) { $msg = "$msg ($($b + 1)/$($batches.Count))" }

                    # 只提交这一段涉及的文件，别把其他已经暂存的改动一并提交。
                    # 提交信息里的中文在控制台上会显示成乱码（git 输出 UTF-8，cmd 按本地代码页读），
                    # 但存进仓库的内容是正确的，所以这里不直接回显 git 的原始输出。
                    Invoke-Git -Arguments (@('commit', '--only', '-m', $msg, '--') + $paths) | Out-Null
                    $short = Invoke-Git -Arguments @('rev-parse', '--short', 'HEAD')
                    Write-Host "已提交存档：$short  $msg"

                    if (-not (Invoke-PushWithRetry -Attempts $PushRetries)) {
                        if ($batches.Count -gt 1) {
                            if ($b -eq 0) {
                                Show-PushFailHelp -Stage '分段推送第 1 段就没推上去，云端还是旧进度。'
                            }
                            else {
                                Show-PushFailHelp -Stage "分段推送中断：前 $b 段已经在云端，第 $($b + 1)/$($batches.Count) 段没推上去。"
                            }
                            Write-Host '剩下的改动还在本地，网络好一些再双击 push.bat，会从断掉的那一段接着推。' -ForegroundColor Yellow
                        }
                        else {
                            Show-PushFailHelp
                        }
                        exit 1
                    }
                }
            }

            Save-SyncState -World $WorldName -Saves $SavesDir
            Write-Host '完成。现在可以叫朋友双击 pull.bat 了。' -ForegroundColor Green
        }
    }
}
catch {
    # 统一把异常收成一行可读的中文。直接 throw 到外面时 PowerShell 会把整段
    # 消息按错误格式再刷一遍堆栈，看起来像出了大事，其实只是一句话的提示。
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host '已停在这一步，没有继续改动存档。' -ForegroundColor DarkGray
    exit 1
}
finally {
    if ($worldLock) { $worldLock.Dispose() }
    if ($syncLock) { $syncLock.Dispose() }
}

<#
.SYNOPSIS
    在本机 Minecraft 存档和本仓库的 world/ 目录之间同步。

.DESCRIPTION
    pull  仓库 world/  ->  本机 .minecraft\saves\<世界名>
          覆盖前会把本地存档整份备份一份，搞坏了能回退。

    push  本机存档  ->  仓库 world/
          会先列出这次到底改了哪些文件、多大，你确认之后才提交和推送。
          不想确认就加 -Yes。

    pull 会先更新 Git 仓库，再备份并完整同步本地世界。
    两边的存档目录会保持一致，包括同步文件删除。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('pull', 'push')]
    [string]$Mode,

    # 世界文件夹名。不填就自动列出存档目录让你选。
    [string]$WorldName,

    # 游戏目录（里面要有 saves 那一层）。不填就读仓库根目录的 game-dir.txt，
    # 再不行才退回默认的 %APPDATA%\.minecraft。
    [string]$GameDir,

    # 直接指定存档目录，优先级最高，一般只有测试时才用
    [string]$SavesDir,

    # push 时跳过确认，直接提交推送
    [switch]$Yes
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

if (-not (Test-Path -LiteralPath $SavesDir)) {
    # 第一次玩的人可能连 saves 都还没有，pull 的时候直接建出来
    if ($Mode -eq 'pull') {
        New-Item -ItemType Directory -Path $SavesDir -Force | Out-Null
        Write-Host "存档目录不存在，已新建：$SavesDir" -ForegroundColor Yellow
    }
    else {
        throw @"
找不到存档目录：$SavesDir

你的游戏可能不是默认安装位置。解决办法：
在仓库根目录的 game-dir.txt 里写上游戏目录（含 saves 的那一层），只写路径，例如：

    E:\HMCL\HMCL3.9.1\.minecraft

改完再跑一次就行。
"@
    }
}

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

function Resolve-WorldName {
    param([string]$Name, [string]$Saves, [switch]$AllowNew)

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

    $worlds = @(Get-ChildItem -LiteralPath $Saves -Directory |
                Where-Object { $_.Name -notlike '*.bak-*' } |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') })

    if ($worlds.Count -eq 0) {
        # 全新机器，本地一个世界都没有：让他自己起个名字，pull 会建成这个
        if ($AllowNew) {
            Write-Host '你本地还没有任何世界，这次会新建一个。' -ForegroundColor Cyan
            while ($true) {
                $newName = Read-Host '给这个存档起个名字（随便起，比如 双人世界）'
                if ($newName -and $newName.Trim()) { return $newName.Trim() }
                Write-Host '名字不能为空。' -ForegroundColor Yellow
            }
        }
        throw "这个目录下没有可用的世界：$Saves"
    }

    if ($worlds.Count -eq 1) { return $worlds[0].Name }

    # 列出名字、最后修改时间、体积，方便认出哪个是在玩的那个
    Write-Host '找到多个世界，选一个：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $worlds.Count; $i++) {
        $w = $worlds[$i]
        $bytes = (Get-ChildItem -LiteralPath $w.FullName -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { $bytes = 0 }
        Write-Host ('  [{0}]  {1}  {2,10:N1} MB  ' -f ($i + 1), $w.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), ($bytes / 1MB)) -NoNewline
        Write-Host $w.Name
    }
    while ($true) {
        $pick = Read-Host '输入序号'
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $worlds.Count) {
            return $worlds[$n - 1].Name
        }
        Write-Host '序号不对，重新输入。' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- 主流程

$WorldName = Resolve-WorldName -Name $WorldName -Saves $SavesDir -AllowNew:($Mode -eq 'pull')
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
    Write-Host '[1/3] 检查远端进度'
    Invoke-Git -Arguments @('fetch', $remoteName) | Out-Host
    $behind = [int](Invoke-Git -Arguments @('rev-list', '--count', "HEAD..$upstream"))
    $ahead = [int](Invoke-Git -Arguments @('rev-list', '--count', "$upstream..HEAD"))

    switch ($Mode) {
        'pull' {
            if ($ahead -gt 0) {
                throw '本地还有未推送的提交。请先运行 push.bat 交接本地进度，再拉取。'
            }
            $dirty = Invoke-Git -Arguments @('status', '--porcelain')
            if ($dirty) { throw '仓库中有未提交的改动。请先提交或备份处理这些改动，再拉取。' }

            Invoke-Git -Arguments @('merge', '--ff-only', $upstream) | Out-Host
            # 更新仓库后再验证，支持远端首次加入存档，也防止误导入空目录。
            Assert-World -Path $repoWorld
            Assert-NoLinks -Path $repoWorld

            if (Test-Path -LiteralPath $localWorld) {
                $backup = "$localWorld.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
                Write-Host "[2/3] 备份本地存档 -> $backup"
                Invoke-Robocopy -Source $localWorld -Dest $backup -Backup
            }
            else {
                Write-Host '[2/3] 本地没有这个存档，直接新建'
                New-Item -ItemType Directory -Path $localWorld | Out-Null
                $worldLock = [IO.File]::Open((Join-Path $localWorld 'session.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            }

            Write-Host '[3/3] 导入最新存档'
            Invoke-Robocopy -Source $repoWorld -Dest $localWorld
            Write-Host "完成。存档在：$localWorld" -ForegroundColor Green
        }

        'push' {
            Assert-World -Path $localWorld
            if ($behind -gt 0) {
                throw "远端有 $behind 个本地没有的提交。请先备份当前游戏存档，再拉取并确认采用哪份进度。"
            }

            # 先检查提交身份，避免复制后才发现 Git 尚未配置姓名和邮箱。
            Invoke-Git -Arguments @('var', 'GIT_AUTHOR_IDENT') | Out-Null
            Invoke-Git -Arguments @('var', 'GIT_COMMITTER_IDENT') | Out-Null
            Write-Host '[2/3] 预览存档变化（字节数为文件大小，传输量取决于 Git 压缩）'
            Invoke-Robocopy -Source $localWorld -Dest $repoWorld -Preview
            if (-not $Yes) {
                Write-Host '目标目录将与本地世界一致，包括删除目标中多出的存档文件。' -ForegroundColor Yellow
                $answer = Read-Host '确认同步并推送？(Y/n)'
                if ($answer -and $answer.Trim().ToLower() -notin @('', 'y', 'yes')) {
                    Write-Host '已取消。' -ForegroundColor Yellow
                    exit 0
                }
            }

            Invoke-Robocopy -Source $localWorld -Dest $repoWorld
            Invoke-Git -Arguments @('add', '--', 'world')
            $changes = Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--', 'world')
            if ($changes) {
                Invoke-Git -Arguments @('diff', '--cached', '--stat', '--', 'world') | Out-Host
                $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
                # 只提交存档，避免把其他已经暂存的文件一并提交。
                Invoke-Git -Arguments @('commit', '--only', '-m', "sync: $WorldName @ $stamp", '--', 'world') | Out-Host
            }

            Write-Host '[3/3] 推送进度'
            # 即使文件没有新变化，也推送先前因断网或权限问题留在本地的提交。
            # 失败时保留提交，恢复网络或权限后再次双击 push.bat 即可重试。
            Invoke-Git -Arguments @('push') | Out-Host
            Write-Host '完成。现在可以叫朋友双击 pull.bat 了。' -ForegroundColor Green
        }
    }
}
finally {
    if ($worldLock) { $worldLock.Dispose() }
    if ($syncLock) { $syncLock.Dispose() }
}

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
    pull 会先更新 Git 仓库，再备份并完整同步本地世界。
    两边的存档目录会保持一致，包括同步文件删除。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -Yes

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -WorldName "新的世界 (2)"
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
            Invoke-Git -Arguments @('add', '--', 'world')
            $changes = Invoke-Git -Arguments @('diff', '--cached', '--name-only', '--', 'world')
            if ($changes) {
                Invoke-Git -Arguments @('diff', '--cached', '--stat', '--', 'world') | Out-Host
                $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
                # 只提交存档，避免把其他已经暂存的文件一并提交。
                # 提交信息里的中文在控制台上会显示成乱码（git 输出 UTF-8，cmd 按本地代码页读），
                # 但存进仓库的内容是正确的，所以这里不直接显示 git 的原始输出。
                Invoke-Git -Arguments @('commit', '--only', '-m', "sync: $WorldName @ $stamp", '--', 'world') | Out-Null
                $head = Invoke-Git -Arguments @('rev-parse', '--short', 'HEAD')
                Write-Host "已提交存档：$head  sync: $WorldName @ $stamp"
            }

            Write-Host '[4/4] 推送进度'
            # 即使文件没有新变化，也推送先前因断网或权限问题留在本地的提交。
            # 失败时保留提交，恢复网络或权限后再次双击 push.bat 即可重试。
            Invoke-Git -Arguments @('push') | Out-Host
            Save-SyncState -World $WorldName -Saves $SavesDir
            Write-Host '完成。现在可以叫朋友双击 pull.bat 了。' -ForegroundColor Green
        }
    }
}
finally {
    if ($worldLock) { $worldLock.Dispose() }
    if ($syncLock) { $syncLock.Dispose() }
}

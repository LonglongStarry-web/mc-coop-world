<#
.SYNOPSIS
    在本机 Minecraft 存档和本仓库的 world/ 目录之间同步。

.DESCRIPTION
    pull  仓库 world/  ->  本机 .minecraft\saves\<世界名>
          覆盖前会把本地存档整份备份一份，搞坏了能回退。

    push  本机存档  ->  仓库 world/
          会先列出这次到底改了哪些文件、多大，你确认之后才提交和推送。
          不想确认就加 -Yes。

    不会删除任何文件，只会新增和覆盖。宁可留下旧文件，也不冒险删掉你的区块。

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

    # 默认读 %APPDATA%\.minecraft\saves
    [string]$SavesDir = (Join-Path $env:APPDATA '.minecraft\saves'),

    # push 时跳过确认，直接提交推送
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$repoWorld = Join-Path $repoRoot 'world'

# ---------------------------------------------------------------- 小工具

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Dest)

    if (-not (Test-Path -LiteralPath $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }

    # /E  含子目录（含空目录）
    # /XF 排除仓库里的占位文件，别让它们被拷进存档目录
    & robocopy $Source $Dest /E /XF '.gitkeep' 'README.md' /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE

    # robocopy 退出码 0-7 都算正常，>=8 才是真失败
    if ($code -ge 8) { throw "robocopy 失败，退出码 $code" }
}

function Resolve-WorldName {
    param([string]$Name, [string]$Saves)

    if ($Name) {
        $path = Join-Path $Saves $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "找不到存档目录：$path" }
        return $Name
    }

    if (-not (Test-Path -LiteralPath $Saves)) { throw "找不到 Minecraft 存档目录：$Saves" }

    $worlds = @(Get-ChildItem -LiteralPath $Saves -Directory |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') })

    if ($worlds.Count -eq 0) { throw "这个目录下没有可用的世界：$Saves" }
    if ($worlds.Count -eq 1) { return $worlds[0].Name }

    Write-Host '找到多个世界，选一个：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $worlds.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $worlds[$i].Name)
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

$WorldName  = Resolve-WorldName -Name $WorldName -Saves $SavesDir
$localWorld = Join-Path $SavesDir $WorldName

Write-Host "仓库：$repoRoot"
Write-Host "世界：$WorldName"
Write-Host ''

switch ($Mode) {

    # ============================================================ pull
    'pull' {
        if (-not (Test-Path -LiteralPath $repoWorld)) { throw "仓库里没有 world 文件夹：$repoWorld" }

        if (Test-Path -LiteralPath $localWorld) {
            $backup = "$localWorld.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Host "[1/2] 备份本地存档 -> $(Split-Path -Leaf $backup)"
            Copy-Item -LiteralPath $localWorld -Destination $backup -Recurse -Force
        }

        Write-Host '[2/2] 拉取 仓库 world/ -> 本地存档'
        Invoke-Robocopy -Source $repoWorld -Dest $localWorld

        Write-Host ''
        Write-Host '完成。进游戏前确认游戏版本和模组列表跟朋友一致。' -ForegroundColor Green
    }

    # ============================================================ push
    'push' {
        if (-not (Test-Path -LiteralPath $localWorld)) { throw "找不到本地存档：$localWorld" }

        # --- 先确认远端没有别人推的新东西，否则等下推上去会被拒 ---
        Write-Host '[1/4] 检查远端有没有新进度'
        $fetched = $false
        try {
            & git -C $repoRoot fetch --quiet origin 2>$null
            $fetched = ($LASTEXITCODE -eq 0)
        }
        catch {
            $fetched = $false
        }

        if ($fetched) {
            $behind = & git -C $repoRoot rev-list --count 'HEAD..@{u}' 2>$null
            if ($behind -and [int]$behind -gt 0) {
                Write-Host ''
                Write-Host "远端有 $behind 个你本地没有的提交——朋友已经推过新进度了。" -ForegroundColor Red
                Write-Host '直接推会冲突。存档是二进制文件，合不了，只能二选一。' -ForegroundColor Red
                Write-Host ''
                Write-Host '所以这次什么都没做。下一步：' -ForegroundColor Yellow
                Write-Host '  · 先跑 pull：把朋友的进度拉下来（你本地这份会自动备份，想回退改回名字就行）' -ForegroundColor Yellow
                Write-Host '  · 如果确定要保留你本地这份、不要朋友那份，再来找我，这种覆盖操作我单独帮你做' -ForegroundColor Yellow
                exit 1
            }
            Write-Host '      远端是最新的，可以推'
        }
        else {
            Write-Host '      没连上远端，跳过检查' -ForegroundColor Yellow
        }

        # --- 复制到仓库工作区 ---
        Write-Host '[2/4] 把本地存档复制进仓库 world/'
        Invoke-Robocopy -Source $localWorld -Dest $repoWorld

        # --- 算出这次到底改了什么 ---
        Write-Host '[3/4] 对比差异'
        & git -C $repoRoot add -- world 2>$null

        $numstat = & git -C $repoRoot diff --cached --numstat -- world
        if (-not $numstat -or $numstat.Count -eq 0) {
            Write-Host ''
            Write-Host '存档和仓库里完全一致，没有需要推送的内容。' -ForegroundColor Green
            exit 0
        }

        $total = 0
        $rows  = @()
        foreach ($line in $numstat) {
            $cols = $line -split "`t"
            if ($cols.Count -lt 3) { continue }

            $rel  = $cols[2]
            $full = Join-Path $repoRoot ($rel -replace '/', '\')

            if (Test-Path -LiteralPath $full) {
                $size = (Get-Item -LiteralPath $full).Length
                $kind = '新增/修改'
            }
            else {
                $size = 0
                $kind = '删除'
            }

            $total += $size
            $rows  += [pscustomobject]@{ Kind = $kind; Size = $size; Path = $rel }
        }

        Write-Host ''
        Write-Host ('本次改动 {0} 个文件：' -f $rows.Count) -ForegroundColor Cyan
        foreach ($r in ($rows | Sort-Object -Property Size -Descending)) {
            $label = if ($r.Kind -eq '删除') { $r.Path + '  (已删除)' } else { $r.Path }
            Write-Host ('{0,12}  {1}' -f (Format-Size $r.Size), $label)
        }
        Write-Host ''
        Write-Host ('合计 {0}' -f (Format-Size $total))
        Write-Host '这是这批文件的总大小，实际上传的字节一般远小于它：' -ForegroundColor Yellow
        Write-Host 'Git 只传变化的部分，没动过的文件一个字节都不发，改过的 .mca 也只发增量。' -ForegroundColor Yellow

        if (-not $Yes) {
            Write-Host ''
            $ans = Read-Host '确认推送？(Y/n)'
            if ($ans) {
                $a = $ans.Trim().ToLower()
                if ($a -ne '' -and $a -ne 'y' -and $a -ne 'yes') {
                    & git -C $repoRoot reset --quiet 2>$null
                    # 把工作区也还原回去，不然仓库里会留一堆没提交的改动
                    & git -C $repoRoot checkout -- world 2>$null
                    Write-Host '已取消，什么都没提交。' -ForegroundColor Yellow
                    exit 0
                }
            }
        }

        # --- 提交并推送 ---
        Write-Host ''
        Write-Host '[4/4] 提交并推送'
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        & git -C $repoRoot commit --quiet -m "sync: $WorldName @ $stamp"
        if ($LASTEXITCODE -ne 0) {
            Write-Host '提交失败，可能没有实际变化。' -ForegroundColor Red
            exit 1
        }

        & git -C $repoRoot push

        if ($LASTEXITCODE -ne 0) {
            Write-Host ''
            Write-Host '推送被拒绝。撤销这次提交，什么都没丢：' -ForegroundColor Red
            Write-Host '    git reset --soft HEAD~1' -ForegroundColor Red
            Write-Host '然后跑 pull 把远端拉下来看看。' -ForegroundColor Red
            exit 1
        }

        Write-Host ''
        Write-Host '完成。现在可以叫朋友 pull 了。' -ForegroundColor Green
    }
}

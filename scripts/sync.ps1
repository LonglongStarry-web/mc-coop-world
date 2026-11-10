<#
.SYNOPSIS
    在本机 Minecraft 存档和本仓库的 world/ 目录之间同步。

.DESCRIPTION
    pull : 仓库 world/  ->  本机 .minecraft\saves\<WorldName>（覆盖前自动整份备份）
    push : 本机存档      ->  仓库 world/，然后 git add / commit / push

    不会删除任何文件，只会新增和覆盖。宁可留下旧文件，也不冒险删掉你的区块。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 pull -WorldName 我的世界

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 push -WorldName 我的世界
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('pull', 'push')]
    [string]$Mode,

    # 世界的文件夹名（就是 .minecraft\saves 下面那个名字）
    [Parameter(Mandatory = $true)]
    [string]$WorldName,

    # 默认读 %APPDATA%\.minecraft\saves，别的一般不用改
    [string]$SavesDir = (Join-Path $env:APPDATA '.minecraft\saves')
)

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$repoWorld  = Join-Path $repoRoot 'world'
$localWorld = Join-Path $SavesDir $WorldName

function Invoke-Robocopy {
    param([string]$Source, [string]$Dest)

    if (-not (Test-Path -LiteralPath $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }

    # /E  含子目录（含空目录）
    # /XF 排除仓库里的占位文件，避免它们被拷进存档目录
    & robocopy $Source $Dest /E /XF '.gitkeep' 'README.md' /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE

    # robocopy 退出码 0-7 都算正常，>=8 才是真失败
    if ($code -ge 8) { throw "robocopy 失败，退出码 $code" }
}

switch ($Mode) {

    'pull' {
        if (-not (Test-Path -LiteralPath $repoWorld)) { throw "仓库里没有 world 文件夹：$repoWorld" }

        if (Test-Path -LiteralPath $localWorld) {
            $backup = "$localWorld.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Host "[1/2] 备份本地存档 -> $backup"
            Copy-Item -LiteralPath $localWorld -Destination $backup -Recurse -Force
        }

        Write-Host "[2/2] 拉取 仓库 world/ -> $localWorld"
        Invoke-Robocopy -Source $repoWorld -Dest $localWorld

        Write-Host ""
        Write-Host "完成。进游戏前确认版本号和模组与朋友一致。" -ForegroundColor Green
    }

    'push' {
        if (-not (Test-Path -LiteralPath $localWorld)) { throw "找不到本地存档：$localWorld" }

        Write-Host "提醒：推送前请先完全退出游戏，否则存档可能只写了一半。" -ForegroundColor Yellow

        Write-Host "[1/2] 复制 本地存档 -> 仓库 world/"
        Invoke-Robocopy -Source $localWorld -Dest $repoWorld

        Write-Host "[2/2] 提交并推送"
        Push-Location -LiteralPath $repoRoot
        try {
            & git add -- world
            if ($LASTEXITCODE -ne 0) { throw "git add 失败" }

            $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
            & git commit -m "sync: $WorldName @ $stamp" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "      存档没有变化，跳过提交" -ForegroundColor Yellow
            }

            & git push
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "推送被拒绝：远端有你没有的提交（朋友在你之前推过）。" -ForegroundColor Red
                Write-Host "先把远端的存档拉下来看看要不要合并，再决定推哪一份：" -ForegroundColor Red
                Write-Host "    git pull" -ForegroundColor Red
                Write-Host "存档是二进制文件，冲突只能二选一，别硬合。" -ForegroundColor Red
                exit 1
            }
        }
        finally {
            Pop-Location
        }

        Write-Host ""
        Write-Host "完成。现在可以叫朋友 pull 了。" -ForegroundColor Green
    }
}

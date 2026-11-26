[CmdletBinding()]
param(
    [ValidateSet("Setup", "Repair", "Uninstall")]
    [string]$Action = "Setup",
    [switch]$ForceConfig
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$DistIde = Join-Path $Root "dist\ide"
$DistCli = Join-Path $Root "dist\cli"
$BackupRoot = Join-Path $env:LOCALAPPDATA "antigravity-proxy-system"

function Sync-BackupMotherCopy {
    try {
        if ($Root.TrimEnd('\') -ieq $BackupRoot.TrimEnd('\')) { return }
        if (-not (Test-Path -LiteralPath (Join-Path $DistIde "version.dll") -PathType Leaf)) { return }
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root "deploy.ps1") -Destination (Join-Path $BackupRoot "deploy.ps1") -Force
        $batSrc = Join-Path $Root "一键部署或修复系统代理补丁.bat"
        if (Test-Path -LiteralPath $batSrc -PathType Leaf) {
            Copy-Item -LiteralPath $batSrc -Destination (Join-Path $BackupRoot "一键部署或修复系统代理补丁.bat") -Force
        }
        $dstDist = Join-Path $BackupRoot "dist"
        New-Item -ItemType Directory -Path (Join-Path $dstDist "ide") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dstDist "cli") -Force | Out-Null
        Copy-Item -Path (Join-Path $DistIde "*") -Destination (Join-Path $dstDist "ide") -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $DistCli -PathType Container) {
            Copy-Item -Path (Join-Path $DistCli "*") -Destination (Join-Path $dstDist "cli") -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # 备份母本失败不阻断主部署流程
    }
}

function Find-AntigravityTargets {
    $targets = @()
    $desktopDir = Join-Path $env:LOCALAPPDATA "Programs\antigravity"
    if (Test-Path -LiteralPath (Join-Path $desktopDir "Antigravity.exe") -PathType Leaf) {
        $targets += [pscustomobject]@{ Kind = "Desktop"; Name = "Antigravity 桌面版"; Dir = $desktopDir; Variant = "ide"; ExeName = "Antigravity" }
    }
    $ideDir = Join-Path $env:LOCALAPPDATA "Programs\Antigravity IDE"
    if (Test-Path -LiteralPath (Join-Path $ideDir "Antigravity IDE.exe") -PathType Leaf) {
        $targets += [pscustomobject]@{ Kind = "IDE"; Name = "Antigravity IDE"; Dir = $ideDir; Variant = "ide"; ExeName = "Antigravity IDE" }
    }
    $cliDir = Join-Path $env:LOCALAPPDATA "agy\bin"
    if (-not (Test-Path -LiteralPath (Join-Path $cliDir "agy.exe") -PathType Leaf)) {
        $cmd = Get-Command agy -ErrorAction SilentlyContinue
        if ($cmd) { $cliDir = Split-Path -Parent $cmd.Source }
    }
    if (Test-Path -LiteralPath (Join-Path $cliDir "agy.exe") -PathType Leaf) {
        $targets += [pscustomobject]@{ Kind = "CLI"; Name = "Antigravity CLI (agy)"; Dir = $cliDir; Variant = "cli"; ExeName = "agy" }
    }
    return $targets
}

function Files-Identical([string]$PathA, [string]$PathB) {
    if (-not (Test-Path -LiteralPath $PathA -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $PathB -PathType Leaf)) { return $false }
    $itemA = Get-Item -LiteralPath $PathA
    $itemB = Get-Item -LiteralPath $PathB
    if ($itemA.Length -ne $itemB.Length) { return $false }
    try {
        $hA = (Get-FileHash -LiteralPath $PathA -Algorithm SHA256).Hash
        $hB = (Get-FileHash -LiteralPath $PathB -Algorithm SHA256).Hash
        return $hA -eq $hB
    } catch {
        return $true
    }
}

function Copy-SafeFile([string]$Src, [string]$Dst, [string]$AppName) {
    if (Files-Identical $Src $Dst) {
        return "same"
    }
    try {
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        return "copied"
    } catch {
        Write-Host ("  [警告] 文件正被 {0} 占用，请完全退出该程序后重试: {1}" -f $AppName, $Dst) -ForegroundColor Yellow
        return "locked"
    }
}

if ($Action -ne "Uninstall") {
    Sync-BackupMotherCopy
}

$targets = Find-AntigravityTargets
if ($targets.Count -eq 0) {
    Write-Host "未检测到任何已安装的 Antigravity 产品。" -ForegroundColor Red
    exit 1
}

Write-Host "Antigravity-Proxy 系统代理跟随版 - $Action" -ForegroundColor White
foreach ($t in $targets) {
    Write-Host ""
    Write-Host ("==> {0}: {1}" -f $t.Name, $t.Dir) -ForegroundColor Cyan

    if ($Action -eq "Uninstall") {
        $filesToRemove = if ($t.Variant -eq "ide") { @("version.dll", "config.json") } else { @("dbghelp.dll", "antigravity_proxy.dll", "config.json") }
        foreach ($fn in $filesToRemove) {
            $p = Join-Path $t.Dir $fn
            if (Test-Path -LiteralPath $p) {
                try {
                    Remove-Item -LiteralPath $p -Force
                    Write-Host ("  [已移除] {0}" -f $fn) -ForegroundColor Green
                } catch {
                    Write-Host ("  [跳过] {0} 正被占用，请退出 {1} 后重试" -f $fn, $t.Name) -ForegroundColor Yellow
                }
            }
        }
        continue
    }

    $srcDir = if ($t.Variant -eq "ide") { $DistIde } else { $DistCli }
    $altSrcDir = Join-Path $BackupRoot (Join-Path "dist" $t.Variant)
    $dllFiles = if ($t.Variant -eq "ide") { @("version.dll") } else { @("dbghelp.dll", "antigravity_proxy.dll") }

    foreach ($fn in $dllFiles) {
        $src = Join-Path $srcDir $fn
        $dst = Join-Path $t.Dir $fn
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $altSrc = Join-Path $altSrcDir $fn
            if (Test-Path -LiteralPath $altSrc -PathType Leaf) {
                $src = $altSrc
            } else {
                Write-Host ("  [警告] 缺少母本文件 {0}（如刚克隆仓库请先运行 build-mingw.ps1 编译，或检查杀毒软件拦截）" -f $fn) -ForegroundColor Yellow
                continue
            }
        }
        $wasMissing = -not (Test-Path -LiteralPath $dst -PathType Leaf)
        $res = Copy-SafeFile $src $dst $t.Name
        if ($res -eq "same") {
            Write-Host ("  [已是最新] {0}（补丁已就绪）" -f $fn) -ForegroundColor Green
        } elseif ($res -eq "copied") {
            Write-Host ("  [已部署] {0}" -f $fn) -ForegroundColor Green
            if ($wasMissing) {
                $running = Get-Process -Name $t.ExeName -ErrorAction SilentlyContinue
                if ($running) {
                    Write-Host ("  [提示] {0} 当前正在运行，请完全退出后重新启动以加载补丁。" -f $t.Name) -ForegroundColor Yellow
                }
            }
        }
    }

    $cfgSrc = Join-Path $srcDir "config.json"
    if (-not (Test-Path -LiteralPath $cfgSrc -PathType Leaf)) {
        $cfgSrc = Join-Path $altSrcDir "config.json"
    }
    $cfgDst = Join-Path $t.Dir "config.json"
    if ($Action -eq "Setup" -and ((-not (Test-Path -LiteralPath $cfgDst)) -or $ForceConfig)) {
        if (Test-Path -LiteralPath $cfgSrc -PathType Leaf) {
            $cfgRes = Copy-SafeFile $cfgSrc $cfgDst $t.Name
            if ($cfgRes -eq "same" -or $cfgRes -eq "copied") {
                Write-Host "  [已写入] config.json (mode=system，自动跟随 Windows 系统代理)" -ForegroundColor Green
            }
        }
    } elseif (Test-Path -LiteralPath $cfgDst) {
        Write-Host "  [保留] 已存在 config.json" -ForegroundColor DarkGray
    } elseif ($Action -eq "Repair" -and (Test-Path -LiteralPath $cfgSrc -PathType Leaf)) {
        $cfgRes = Copy-SafeFile $cfgSrc $cfgDst $t.Name
        if ($cfgRes -eq "same" -or $cfgRes -eq "copied") {
            Write-Host "  [已补回] config.json" -ForegroundColor Green
        }
    }
}

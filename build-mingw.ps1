$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$ObjDir = Join-Path $Root "build-mingw-obj"
$DistDir = Join-Path $Root "dist"
$IdeDir = Join-Path $DistDir "ide"
$CliDir = Join-Path $DistDir "cli"

New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
New-Item -ItemType Directory -Path $IdeDir -Force | Out-Null
New-Item -ItemType Directory -Path $CliDir -Force | Out-Null

Write-Host "[1/4] 编译 MinHook 与代理主体 (version.dll)..." -ForegroundColor Cyan
$cFiles = @(
    (Join-Path $Root "src\buffer.c"),
    (Join-Path $Root "src\hook.c"),
    (Join-Path $Root "src\trampoline.c"),
    (Join-Path $Root "src\hde\hde64.c")
)
$cppFiles = @(
    (Join-Path $Root "src\main.cpp"),
    (Join-Path $Root "src\hooks\Hooks.cpp"),
    (Join-Path $Root "src\proxy\VersionProxy.cpp"),
    (Join-Path $Root "src\update\UpdateChecker.cpp"),
    (Join-Path $Root "src\ide\IdeExtensionPrompt.cpp")
)

$objs = @()
foreach ($f in $cFiles) {
    $obj = Join-Path $ObjDir ([IO.Path]::GetFileNameWithoutExtension($f) + ".o")
    & gcc -O2 -c $f -o $obj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败: $f" }
    $objs += $obj
}
foreach ($f in $cppFiles) {
    $obj = Join-Path $ObjDir ([IO.Path]::GetFileNameWithoutExtension($f) + ".o")
    & g++ -O2 -std=c++17 -c $f -o $obj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX -D_WIN32_WINNT=0x0601
    if ($LASTEXITCODE -ne 0) { throw "g++ 编译失败: $f" }
    $objs += $obj
}

$versionDll = Join-Path $IdeDir "version.dll"
& g++ -shared -o $versionDll $objs "$Root\src\proxy\version.def" -lws2_32 -lwinhttp -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "链接 version.dll 失败" }

Write-Host "[2/4] 编译 CLI 侧载入口 (dbghelp.dll)..." -ForegroundColor Cyan
$dbgObj = Join-Path $ObjDir "DbgHelpShim.o"
& g++ -O2 -std=c++17 -c "$Root\src\proxy\DbgHelpShim.cpp" -o $dbgObj -I"$Root\include" -I"$Root\src" -DNOMINMAX -D_WIN32_WINNT=0x0601
if ($LASTEXITCODE -ne 0) { throw "编译 DbgHelpShim.cpp 失败" }

$dbgDll = Join-Path $CliDir "dbghelp.dll"
& g++ -shared -o $dbgDll $dbgObj "$Root\src\proxy\dbghelp.def" -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "链接 dbghelp.dll 失败" }

Copy-Item -LiteralPath $versionDll -Destination (Join-Path $CliDir "antigravity_proxy.dll") -Force

Write-Host "[3/4] 生成默认跟随系统代理的 config.json..." -ForegroundColor Cyan
$configObj = [ordered]@{
    _version = "2.6.4-system"
    log_level = "info"
    proxy = [ordered]@{
        mode = "system"
        host = "127.0.0.1"
        port = 7890
        type = "socks5"
        username = ""
        password = ""
    }
    fake_ip = [ordered]@{
        enabled = $true
        cidr = "198.18.0.0/15"
    }
    timeout = [ordered]@{
        connect = 5000
        send = 5000
        recv = 5000
    }
    child_injection = $true
    child_injection_mode = "filtered"
    target_processes = @(
        "agy.exe",
        "language_server.exe",
        "language_server_windows",
        "Antigravity.exe",
        "Antigravity IDE.exe",
        "node.exe"
    )
    proxy_rules = [ordered]@{
        allowed_ports = @(80, 443, 3478)
        dns_mode = "direct"
        ipv6_mode = "proxy"
        udp_mode = "auto"
        udp_fallback = "block"
    }
    ui = [ordered]@{
        load_notify = "none"
    }
    updates = [ordered]@{
        enabled = $false
    }
}
$jsonText = $configObj | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $IdeDir "config.json"), $jsonText, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $CliDir "config.json"), $jsonText, $utf8NoBom)

Write-Host "[4/4] 编译并运行系统代理单元测试..." -ForegroundColor Cyan
$testExe = Join-Path $ObjDir "test_system_proxy.exe"
& g++ -O2 -std=c++17 "$Root\tests\test_system_proxy.cpp" -o $testExe -I"$Root\include" -I"$Root\src" -DNOMINMAX -D_WIN32_WINNT=0x0601 -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "编译 test_system_proxy.cpp 失败" }
& $testExe
if ($LASTEXITCODE -ne 0) { throw "单元测试失败" }

Write-Host "构建完成！产物位于: $DistDir" -ForegroundColor Green
Get-ChildItem -Recurse $DistDir | Select-Object FullName, Length

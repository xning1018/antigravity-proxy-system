$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
$ObjDir = Join-Path $Root "build-mingw-obj"
$DistDir = Join-Path $Root "dist"
$IdeDir = Join-Path $DistDir "ide"
$CliDir = Join-Path $DistDir "cli"

New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
New-Item -ItemType Directory -Path $IdeDir -Force | Out-Null
New-Item -ItemType Directory -Path $CliDir -Force | Out-Null

# 清理历史遗留的双层加载壳文件
$legacyCliDll = Join-Path $CliDir "antigravity_proxy.dll"
if (Test-Path -LiteralPath $legacyCliDll) { Remove-Item -LiteralPath $legacyCliDll -Force }

Write-Host "[1/4] 编译 MinHook、共享代理内核与 PE 版本资源..." -ForegroundColor Cyan
$cFiles = @(
    (Join-Path $Root "src\buffer.c"),
    (Join-Path $Root "src\hook.c"),
    (Join-Path $Root "src\trampoline.c"),
    (Join-Path $Root "src\hde\hde64.c")
)
$sharedCppFiles = @(
    (Join-Path $Root "src\hooks\Hooks.cpp"),
    (Join-Path $Root "src\update\UpdateChecker.cpp"),
    (Join-Path $Root "src\ide\IdeExtensionPrompt.cpp")
)

$sharedObjs = @()
foreach ($f in $cFiles) {
    $obj = Join-Path $ObjDir ([IO.Path]::GetFileNameWithoutExtension($f) + ".o")
    & gcc -O2 -c $f -o $obj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败: $f" }
    $sharedObjs += $obj
}
foreach ($f in $sharedCppFiles) {
    $obj = Join-Path $ObjDir ([IO.Path]::GetFileNameWithoutExtension($f) + ".o")
    & g++ -O2 -std=c++17 -c $f -o $obj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX -D_WIN32_WINNT=0x0601
    if ($LASTEXITCODE -ne 0) { throw "g++ 编译失败: $f" }
    $sharedObjs += $obj
}

# 编译版本资源文件 (.rc -> .res.o)
$verResObj = Join-Path $ObjDir "version_proxy.res.o"
$dbgResObj = Join-Path $ObjDir "dbghelp_proxy.res.o"
& windres "$Root\dll_resources\version_proxy.rc" -O coff -o $verResObj
if ($LASTEXITCODE -ne 0) { throw "windres 编译 version_proxy.rc 失败" }
& windres "$Root\dll_resources\dbghelp_proxy.rc" -O coff -o $dbgResObj
if ($LASTEXITCODE -ne 0) { throw "windres 编译 dbghelp_proxy.rc 失败" }

Write-Host "[2/4] 链接桌面版/IDE 代理主体 (version.dll)..." -ForegroundColor Cyan
$mainVerObj = Join-Path $ObjDir "main_version.o"
$verProxyObj = Join-Path $ObjDir "VersionProxy.o"
& g++ -O2 -std=c++17 -c "$Root\src\main.cpp" -o $mainVerObj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX -D_WIN32_WINNT=0x0601
if ($LASTEXITCODE -ne 0) { throw "编译 main_version 失败" }
& g++ -O2 -std=c++17 -c "$Root\src\proxy\VersionProxy.cpp" -o $verProxyObj -I"$Root\include" -I"$Root\src" -DNOMINMAX -D_WIN32_WINNT=0x0601
if ($LASTEXITCODE -ne 0) { throw "编译 VersionProxy.cpp 失败" }

$versionDll = Join-Path $IdeDir "version.dll"
& g++ -shared -o $versionDll @($sharedObjs + $mainVerObj + $verProxyObj + $verResObj) "$Root\src\proxy\version.def" -lws2_32 -lwinhttp -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "链接 version.dll 失败" }

Write-Host "[3/4] 链接 CLI 单文件直出 DLL (dbghelp.dll)..." -ForegroundColor Cyan
$mainDbgObj = Join-Path $ObjDir "main_dbghelp.o"
$dbgProxyObj = Join-Path $ObjDir "DbgHelpProxy.o"
& g++ -O2 -std=c++17 -c "$Root\src\main.cpp" -o $mainDbgObj -I"$Root\include" -I"$Root\src" -I"$Root\src\hde" -DNOMINMAX -D_WIN32_WINNT=0x0601 -DANTIGRAVITY_PROXY_DBGHELP
if ($LASTEXITCODE -ne 0) { throw "编译 main_dbghelp 失败" }
& g++ -O2 -std=c++17 -c "$Root\src\proxy\DbgHelpProxy.cpp" -o $dbgProxyObj -I"$Root\include" -I"$Root\src" -DNOMINMAX -D_WIN32_WINNT=0x0601
if ($LASTEXITCODE -ne 0) { throw "编译 DbgHelpProxy.cpp 失败" }

$dbgDll = Join-Path $CliDir "dbghelp.dll"
& g++ -shared -o $dbgDll @($sharedObjs + $mainDbgObj + $dbgProxyObj + $dbgResObj) "$Root\src\proxy\dbghelp.def" -lws2_32 -lwinhttp -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "链接 dbghelp.dll 失败" }

Write-Host "[4/4] 生成默认跟随系统代理的 config.json 并运行单元测试..." -ForegroundColor Cyan
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

$testSysExe = Join-Path $ObjDir "test_system_proxy.exe"
& g++ -O2 -std=c++17 "$Root\tests\test_system_proxy.cpp" -o $testSysExe -I"$Root\include" -I"$Root\src" -DNOMINMAX -D_WIN32_WINNT=0x0601 -ladvapi32 -static-libgcc -static-libstdc++
if ($LASTEXITCODE -ne 0) { throw "编译 test_system_proxy.cpp 失败" }
& $testSysExe
if ($LASTEXITCODE -ne 0) { throw "test_system_proxy 失败" }

$testDbgExe = Join-Path $ObjDir "test_dbghelp_shim.exe"
Push-Location $Root
try {
    & g++ -O2 -std=c++17 "tests\test_dbghelp_shim.cpp" -o $testDbgExe -municode -D_WIN32_WINNT=0x0601 -static-libgcc -static-libstdc++
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw "编译 test_dbghelp_shim.cpp 失败" }
& $testDbgExe $dbgDll
if ($LASTEXITCODE -ne 0) { throw "test_dbghelp_shim 失败" }
Write-Host "All DbgHelp single-file shim tests passed!"

Write-Host "构建完成！产物位于: $DistDir" -ForegroundColor Green
Get-ChildItem -Recurse $DistDir | Select-Object FullName, Length

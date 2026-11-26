# Antigravity-Proxy（系统代理自动跟随增强版）

基于开源项目 [yuaotian/antigravity-proxy](https://github.com/yuaotian/antigravity-proxy)（v2.6.4，BSD-2-Clause）二次开发，专门针对**不开 TUN 全局虚拟网卡、仅开启 Windows 系统代理**的场景增强，做到只代理 Antigravity 相关进程、不影响系统其他应用与浏览器，同时自动适配任意代理软件端口与开关状态。

---

## 相比原版的核心改进

1. **自动跟随 Windows 系统代理（`proxy.mode = "system"`）**
   - 实现于 [SystemProxyResolver.hpp](src/core/SystemProxyResolver.hpp) 与 [Config.hpp](src/core/Config.hpp)。
   - 启动及运行期间自动读取 Windows 注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 中的 `ProxyEnable` 与 `ProxyServer`（兼容 `127.0.0.1:7897`、`http://...`、`socks5://...`、`[::1]:...` 以及 `http=...;https=...;socks=...` 分协议格式）。
   - 无需手动修改 `config.json` 端口，换电脑或切换不同代理软件均可开箱即用。
2. **混合端口协议自动探测（SOCKS5 / HTTP）**
   - 实现于 [Hooks.cpp](src/hooks/Hooks.cpp) 中的 `ProbeLocalProxyProtocol`（基于原始未 Hook Socket）。
   - 当系统代理为无协议前缀的混合端口（如 Clash Verge / Mihomo 的 `7890` / `7897` 等）时，在 `DllMain` 之外的首次联网阶段自动做 180ms 轻量本地握手探测：支持 SOCKS5 优先选用 `socks5`（同时支持 TCP 与 UDP Associate），否则自动回退为 `http`（HTTP CONNECT）。
3. **运行期热同步 & 关代理直连兜底**
   - 统一通过 `Config::GetEffectiveProxy()` 为所有连接路径提供线程安全代理配置快照，每 2 秒轻量检查一次系统代理开关与端口变化。
   - 当你在代理软件中临时关闭系统代理时自动切回直连，并对已分配的 FakeIP 地址自动重解析真实 IP 后直连。
4. **CLI 单文件直出 & 完整 PE 版本信息**
   - 将 Antigravity CLI（`agy`）使用的 `dbghelp.dll` 合并为单文件直出（[DbgHelpProxy.cpp](src/proxy/DbgHelpProxy.cpp)），彻底移除双层 `LoadLibrary("antigravity_proxy.dll")` 加载壳，降低杀毒软件启发式误报风险。
   - 为 `version.dll` 与 `dbghelp.dll` 嵌入标准的 Windows PE 版本信息资源（[version_proxy.rc](dll_resources/version_proxy.rc)、[dbghelp_proxy.rc](dll_resources/dbghelp_proxy.rc)）。
5. **一键通用部署与防覆盖修复**
   - 提供 [build-mingw.ps1](build-mingw.ps1)（支持本机 MinGW `g++` 直接编译）与 [deploy.ps1](deploy.ps1) / [一键部署或修复系统代理补丁.bat](一键部署或修复系统代理补丁.bat)。
   - 首次部署时会自动在 `%LOCALAPPDATA%\antigravity-proxy-system` 同步一份母本；后续即使 Antigravity 自动更新清除了补丁，双击桌面或原目录的 `.bat` 即可一键补回。

---

## 快速使用

### 方式 A：直接下载编译好的打包产物（推荐普通用户）
1. 从 Releases 下载压缩包并解压。
2. 在你的代理软件中开启 **「系统代理」**（建议出站规则使用 Rule 规则模式，不需要开 TUN 模式）。
3. 退出所有 Antigravity 进程后，双击运行 **`一键部署或修复系统代理补丁.bat`**（会自动检测安装在本机的 Antigravity 桌面版、Antigravity IDE 与 Antigravity CLI）。
4. 重新打开 Antigravity 即可生效。

### 方式 B：从源码自行编译（MinGW 或 Visual Studio / CMake）

**使用 MinGW（PowerShell）：**
```powershell
.\build-mingw.ps1
.\deploy.ps1 -Action Setup
```

**使用 Visual Studio 2022 + CMake：**
```powershell
.\build.ps1 -Clean -Config Release -Arch x64 -RunTests
```

---

## 日常维护与卸载

- **客户端更新后补丁失效**：完全退出 Antigravity 相关进程，重新双击 **`一键部署或修复系统代理补丁.bat`**（或执行 `.\deploy.ps1 -Action Repair`）即可恢复；原有 `config.json` 配置会自动保留。
- **彻底卸载还原**：
  ```powershell
  .\deploy.ps1 -Action Uninstall
  ```

---

## 开源协议与致谢

- 本项目基于 [yuaotian/antigravity-proxy](https://github.com/yuaotian/antigravity-proxy) 修改，遵循 **BSD-2-Clause** 开源协议（详见 [LICENSE.txt](LICENSE.txt)）。
- 内嵌 MinHook 依赖版权归原作者所有（详见 [AUTHORS.txt](AUTHORS.txt)）。

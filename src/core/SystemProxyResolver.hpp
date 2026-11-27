#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <functional>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <vector>
#include "Logger.hpp"

namespace Core {

    struct ResolvedSystemProxy {
        bool enabled = false;
        std::string host = "127.0.0.1";
        int port = 0;
        std::string type = "socks5"; // "socks5" or "http"
        bool needsProbe = false;     // true when raw proxy string has no explicit scheme
        std::string rawServer;
    };

    namespace Detail {
        inline std::string ToLowerAscii(std::string s) {
            std::transform(s.begin(), s.end(), s.begin(),
                           [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            return s;
        }

        inline std::string TrimAscii(std::string s) {
            auto isWs = [](unsigned char c) { return std::isspace(c) != 0; };
            size_t b = 0;
            while (b < s.size() && isWs(static_cast<unsigned char>(s[b]))) ++b;
            size_t e = s.size();
            while (e > b && isWs(static_cast<unsigned char>(s[e - 1]))) --e;
            return s.substr(b, e - b);
        }

        inline std::string WideToUtf8Simple(const std::wstring& w) {
            if (w.empty()) return "";
            int len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
            if (len <= 0) return "";
            std::string out(static_cast<size_t>(len), '\0');
            WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), &out[0], len, nullptr, nullptr);
            return out;
        }

        inline bool ParseHostPortToken(std::string token, std::string* outHost, int* outPort) {
            if (!outHost || !outPort) return false;
            token = TrimAscii(std::move(token));
            if (token.empty()) return false;

            // Strip optional path/query after host:port
            const size_t slashPos = token.find('/');
            if (slashPos != std::string::npos) {
                token = token.substr(0, slashPos);
            }

            std::string host;
            std::string portStr;
            if (!token.empty() && token.front() == '[') {
                const size_t closeBracket = token.find(']');
                if (closeBracket == std::string::npos) return false;
                host = token.substr(1, closeBracket - 1);
                if (closeBracket + 1 < token.size() && token[closeBracket + 1] == ':') {
                    portStr = token.substr(closeBracket + 2);
                }
            } else {
                const size_t colon = token.rfind(':');
                if (colon == std::string::npos) {
                    host = token;
                } else {
                    host = token.substr(0, colon);
                    portStr = token.substr(colon + 1);
                }
            }

            host = TrimAscii(std::move(host));
            portStr = TrimAscii(std::move(portStr));
            if (host.empty() || portStr.empty()) return false;

            int port = 0;
            for (char ch : portStr) {
                if (!std::isdigit(static_cast<unsigned char>(ch))) return false;
                port = port * 10 + (ch - '0');
                if (port > 65535) return false;
            }
            if (port <= 0 || port > 65535) return false;

            *outHost = host;
            *outPort = port;
            return true;
        }

        inline bool ParseSingleEndpoint(std::string raw, std::string* outScheme, std::string* outHost, int* outPort, bool* outHasExplicitScheme) {
            raw = TrimAscii(std::move(raw));
            if (raw.empty()) return false;

            std::string lower = ToLowerAscii(raw);
            std::string scheme;
            bool explicitScheme = false;

            const size_t schemeSep = lower.find("://");
            if (schemeSep != std::string::npos) {
                scheme = lower.substr(0, schemeSep);
                raw = raw.substr(schemeSep + 3);
                explicitScheme = true;
            }

            std::string host;
            int port = 0;
            if (!ParseHostPortToken(raw, &host, &port)) return false;

            if (outScheme) {
                if (scheme == "socks" || scheme == "socks5" || scheme == "socks5h") {
                    *outScheme = "socks5";
                } else if (scheme == "http" || scheme == "https") {
                    *outScheme = "http";
                } else if (scheme.empty()) {
                    *outScheme = "socks5";
                    explicitScheme = false;
                } else {
                    return false;
                }
            }
            if (outHost) *outHost = host;
            if (outPort) *outPort = port;
            if (outHasExplicitScheme) *outHasExplicitScheme = explicitScheme;
            return true;
        }
    } // namespace Detail

    // 解析 Windows 注册表 Internet Settings 的 ProxyServer 字符串
    // 支持格式：
    //   1) "127.0.0.1:7897" （混合端口，标记 needsProbe = true）
    //   2) "http://127.0.0.1:7897" / "socks5://127.0.0.1:10808"
    //   3) "http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891"
    inline ResolvedSystemProxy ParseWindowsProxyServerString(bool proxyEnable, const std::string& proxyServer) {
        ResolvedSystemProxy res;
        res.enabled = proxyEnable;
        res.rawServer = Detail::TrimAscii(proxyServer);
        if (!proxyEnable || res.rawServer.empty()) {
            res.enabled = false;
            res.port = 0;
            return res;
        }

        // 若不包含 ';' 和 '='，按单一地址解析
        if (res.rawServer.find(';') == std::string::npos && res.rawServer.find('=') == std::string::npos) {
            std::string scheme, host;
            int port = 0;
            bool explicitScheme = false;
            if (Detail::ParseSingleEndpoint(res.rawServer, &scheme, &host, &port, &explicitScheme)) {
                res.host = host;
                res.port = port;
                res.type = scheme;
                res.needsProbe = !explicitScheme;
                return res;
            }
            res.enabled = false;
            res.port = 0;
            return res;
        }

        // 分协议字符串解析: http=...;https=...;socks=...
        struct Candidate {
            int priority = 0; // socks5=3, https=2, http=1
            std::string scheme;
            std::string host;
            int port = 0;
            bool explicitScheme = true;
        };
        std::vector<Candidate> candidates;

        size_t start = 0;
        while (start < res.rawServer.size()) {
            size_t end = res.rawServer.find(';', start);
            if (end == std::string::npos) end = res.rawServer.size();
            std::string item = Detail::TrimAscii(res.rawServer.substr(start, end - start));
            start = end + 1;
            if (item.empty()) continue;

            const size_t eq = item.find('=');
            if (eq == std::string::npos) {
                std::string scheme, host;
                int port = 0;
                bool explicitScheme = false;
                if (Detail::ParseSingleEndpoint(item, &scheme, &host, &port, &explicitScheme)) {
                    candidates.push_back({1, scheme, host, port, explicitScheme});
                }
                continue;
            }

            const std::string key = Detail::ToLowerAscii(Detail::TrimAscii(item.substr(0, eq)));
            const std::string val = Detail::TrimAscii(item.substr(eq + 1));
            std::string scheme, host;
            int port = 0;
            bool explicitScheme = false;
            if (!Detail::ParseSingleEndpoint(val, &scheme, &host, &port, &explicitScheme)) {
                continue;
            }
            if (key == "socks" || key == "socks5") {
                candidates.push_back({3, "socks5", host, port, true});
            } else if (key == "https") {
                candidates.push_back({2, "http", host, port, true});
            } else if (key == "http") {
                candidates.push_back({1, "http", host, port, true});
            }
        }

        if (candidates.empty()) {
            res.enabled = false;
            res.port = 0;
            return res;
        }

        auto best = std::max_element(candidates.begin(), candidates.end(),
                                     [](const Candidate& a, const Candidate& b) {
                                         return a.priority < b.priority;
                                     });
        res.host = best->host;
        res.port = best->port;
        res.type = best->scheme;
        res.needsProbe = !best->explicitScheme;
        return res;
    }

    inline bool ReadWindowsInternetSettingsProxy(bool* outEnable, std::string* outServer, std::string* outAutoConfigUrl = nullptr) {
        if (!outEnable || !outServer) return false;
        *outEnable = false;
        outServer->clear();
        if (outAutoConfigUrl) outAutoConfigUrl->clear();

        HKEY hKey = nullptr;
        const wchar_t* subKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
        if (RegOpenKeyExW(HKEY_CURRENT_USER, subKey, 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
            return false;
        }

        DWORD enableVal = 0;
        DWORD enableSize = sizeof(enableVal);
        DWORD enableType = 0;
        if (RegQueryValueExW(hKey, L"ProxyEnable", nullptr, &enableType,
                             reinterpret_cast<LPBYTE>(&enableVal), &enableSize) == ERROR_SUCCESS &&
            enableType == REG_DWORD) {
            *outEnable = (enableVal != 0);
        }

        wchar_t serverBuf[1024] = {0};
        DWORD serverSize = sizeof(serverBuf) - sizeof(wchar_t);
        DWORD serverType = 0;
        if (RegQueryValueExW(hKey, L"ProxyServer", nullptr, &serverType,
                             reinterpret_cast<LPBYTE>(serverBuf), &serverSize) == ERROR_SUCCESS &&
            (serverType == REG_SZ || serverType == REG_EXPAND_SZ)) {
            serverBuf[(sizeof(serverBuf) / sizeof(wchar_t)) - 1] = L'\0';
            *outServer = Detail::WideToUtf8Simple(std::wstring(serverBuf));
        }

        if (outAutoConfigUrl) {
            wchar_t pacBuf[1024] = {0};
            DWORD pacSize = sizeof(pacBuf) - sizeof(wchar_t);
            DWORD pacType = 0;
            if (RegQueryValueExW(hKey, L"AutoConfigURL", nullptr, &pacType,
                                 reinterpret_cast<LPBYTE>(pacBuf), &pacSize) == ERROR_SUCCESS &&
                (pacType == REG_SZ || pacType == REG_EXPAND_SZ)) {
                pacBuf[(sizeof(pacBuf) / sizeof(wchar_t)) - 1] = L'\0';
                *outAutoConfigUrl = Detail::TrimAscii(Detail::WideToUtf8Simple(std::wstring(pacBuf)));
            }
        }

        RegCloseKey(hKey);
        return true;
    }

    // 探测回调类型：返回 "socks5"、"http" 或 ""（端口不可达）
    using ProxyProtocolProbeFn = std::string(*)(const std::string& host, int port);

    class SystemProxyTracker {
    private:
        mutable std::shared_mutex m_mtx;
        mutable std::mutex m_probeMtx;
        ULONGLONG m_lastCheckTick = 0;
        ULONGLONG m_lastProbeTick = 0;
        bool m_initialized = false;
        bool m_lastEnable = false;
        std::string m_lastRawServer;
        std::string m_lastAutoConfigUrl;
        ResolvedSystemProxy m_cached;
        ProxyProtocolProbeFn m_probeFn = nullptr;
        static constexpr ULONGLONG kRefreshIntervalMs = 2000;

    public:
        void SetProbeCallback(ProxyProtocolProbeFn fn) {
            std::unique_lock<std::shared_mutex> lock(m_mtx);
            m_probeFn = fn;
        }

        // 单元测试辅助：直接注入模拟的系统代理状态，避免依赖本机注册表
        void SetStateForTest(bool enable, const std::string& server) {
            ResolvedSystemProxy parsed = ParseWindowsProxyServerString(enable, server);
            std::unique_lock<std::shared_mutex> lock(m_mtx);
            m_initialized = true;
            m_lastCheckTick = GetTickCount64();
            m_lastProbeTick = 0;
            m_lastEnable = enable;
            m_lastRawServer = server;
            m_lastAutoConfigUrl.clear();
            m_cached = parsed;
        }

        // 在 DllMain 等安全阶段仅读取注册表（绝不发起 Socket 探测）
        ResolvedSystemProxy LoadInitialFromRegistry() {
            bool enable = false;
            std::string server;
            std::string autoConfigUrl;
            ReadWindowsInternetSettingsProxy(&enable, &server, &autoConfigUrl);
            ResolvedSystemProxy parsed = ParseWindowsProxyServerString(enable, server);

            std::unique_lock<std::shared_mutex> lock(m_mtx);
            m_initialized = true;
            m_lastCheckTick = GetTickCount64();
            m_lastProbeTick = 0;
            m_lastEnable = enable;
            m_lastRawServer = server;
            m_lastAutoConfigUrl = autoConfigUrl;
            m_cached = parsed;
            if ((!m_cached.enabled || m_cached.port == 0) && !autoConfigUrl.empty()) {
                Logger::Warn("[SystemProxy] 检测到 Windows PAC 自动代理脚本 (" + autoConfigUrl +
                             ")，当前仅支持系统代理（全局/规则）模式；如需自动跟随请开启系统代理");
            }
            return m_cached;
        }

        // 运行期热同步：每 2 秒检查一次注册表变化，且仅当无显式协议时调用 probeFn 探测混合端口
        ResolvedSystemProxy GetCurrent(bool allowProbe) {
            const ULONGLONG now = GetTickCount64();
            {
                std::shared_lock<std::shared_mutex> lock(m_mtx);
                const bool dueCheck = !m_initialized || (now - m_lastCheckTick) >= kRefreshIntervalMs;
                const bool dueProbe = allowProbe && m_cached.enabled && m_cached.port > 0 &&
                                      m_cached.needsProbe && m_probeFn != nullptr &&
                                      (m_lastProbeTick == 0 || (now - m_lastProbeTick) >= kRefreshIntervalMs);
                if (!dueCheck && !dueProbe) {
                    return m_cached;
                }
            }

            // 串行化注册表同步与首次协议探测，避免启动高并发阶段其他线程拿到未探测的默认 socks5 类型
            std::lock_guard<std::mutex> probeGuard(m_probeMtx);
            const ULONGLONG nowLocked = GetTickCount64();
            bool dueCheck = false;
            {
                std::shared_lock<std::shared_mutex> lock(m_mtx);
                dueCheck = !m_initialized || (nowLocked - m_lastCheckTick) >= kRefreshIntervalMs;
                const bool dueProbe = allowProbe && m_cached.enabled && m_cached.port > 0 &&
                                      m_cached.needsProbe && m_probeFn != nullptr &&
                                      (m_lastProbeTick == 0 || (nowLocked - m_lastProbeTick) >= kRefreshIntervalMs);
                if (!dueCheck && !dueProbe) {
                    return m_cached;
                }
            }

            bool enable = false;
            std::string server;
            std::string autoConfigUrl;
            if (dueCheck) {
                ReadWindowsInternetSettingsProxy(&enable, &server, &autoConfigUrl);
            }

            ProxyProtocolProbeFn probeFnCopy = nullptr;
            bool needProbe = false;
            ResolvedSystemProxy candidate;
            {
                std::unique_lock<std::shared_mutex> lock(m_mtx);
                probeFnCopy = m_probeFn;
                if (dueCheck) {
                    m_lastCheckTick = nowLocked;
                    const bool changed = (!m_initialized || enable != m_lastEnable ||
                                          server != m_lastRawServer || autoConfigUrl != m_lastAutoConfigUrl);
                    if (changed) {
                        m_initialized = true;
                        m_lastEnable = enable;
                        m_lastRawServer = server;
                        m_lastAutoConfigUrl = autoConfigUrl;
                        m_lastProbeTick = 0;
                        m_cached = ParseWindowsProxyServerString(enable, server);

                        if (!m_cached.enabled || m_cached.port == 0) {
                            if (!autoConfigUrl.empty()) {
                                Logger::Warn("[SystemProxy] 检测到 PAC 自动代理脚本 (" + autoConfigUrl +
                                             ")，未开启 ProxyEnable，当前走直连模式");
                            } else {
                                Logger::Info("[SystemProxy] Windows 系统代理未开启，已切换为直连模式");
                            }
                        } else if (!m_cached.needsProbe) {
                            Logger::Info("[SystemProxy] 已同步系统代理: " + m_cached.type + "://" +
                                         m_cached.host + ":" + std::to_string(m_cached.port));
                        }
                    }
                }
                if (allowProbe && m_cached.enabled && m_cached.port > 0 && m_cached.needsProbe && probeFnCopy != nullptr &&
                    (m_lastProbeTick == 0 || (nowLocked - m_lastProbeTick) >= kRefreshIntervalMs)) {
                    m_lastProbeTick = nowLocked;
                    candidate = m_cached;
                    needProbe = true;
                }
            }

            if (needProbe && probeFnCopy != nullptr) {
                const std::string detected = probeFnCopy(candidate.host, candidate.port);
                std::unique_lock<std::shared_mutex> lock(m_mtx);
                if (m_cached.host == candidate.host && m_cached.port == candidate.port && m_cached.enabled) {
                    if (detected == "socks5" || detected == "http") {
                        m_cached.type = detected;
                        m_cached.needsProbe = false;
                        Logger::Info("[SystemProxy] 混合端口协议探测成功: " + m_cached.type + "://" +
                                     m_cached.host + ":" + std::to_string(m_cached.port));
                    } else {
                        Logger::Warn("[SystemProxy] 系统代理端口暂不可达或探测超时 (" + m_cached.host + ":" +
                                     std::to_string(m_cached.port) + ")，将继续重试探测");
                    }
                }
            }

            std::shared_lock<std::shared_mutex> lock(m_mtx);
            return m_cached;
        }
    };

} // namespace Core

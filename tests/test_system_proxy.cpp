#include <cassert>
#include <iostream>
#include "core/SystemProxyResolver.hpp"

int main() {
    {
        auto r = Core::ParseWindowsProxyServerString(false, "127.0.0.1:7897");
        assert(!r.enabled);
        assert(r.port == 0);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "127.0.0.1:7897");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 7897);
        assert(r.needsProbe);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "http://127.0.0.1:7897");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 7897);
        assert(r.type == "http");
        assert(!r.needsProbe);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "socks5://127.0.0.1:10808");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 10808);
        assert(r.type == "socks5");
        assert(!r.needsProbe);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 7891);
        assert(r.type == "socks5");
        assert(!r.needsProbe);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "http=127.0.0.1:7890;https=127.0.0.1:7892");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 7892);
        assert(r.type == "http");
        assert(!r.needsProbe);
    }
    {
        auto r = Core::ParseWindowsProxyServerString(true, "[::1]:7897");
        assert(r.enabled);
        assert(r.host == "::1");
        assert(r.port == 7897);
        assert(r.needsProbe);
    }
    {
        // socks4 不受支持，不应覆盖可用的 http 代理
        auto r = Core::ParseWindowsProxyServerString(true, "http=127.0.0.1:7890;socks4=127.0.0.1:1080");
        assert(r.enabled);
        assert(r.host == "127.0.0.1");
        assert(r.port == 7890);
        assert(r.type == "http");
        assert(!r.needsProbe);
    }
    {
        // 探测失败（返回 ""）时不应锁死协议，下次成功探测后才固定协议
        Core::SystemProxyTracker tracker;
        tracker.SetStateForTest(true, "127.0.0.1:7897");
        tracker.SetProbeCallback([](const std::string&, int) -> std::string { return ""; });
        auto r1 = tracker.GetCurrent(true);
        assert(r1.enabled);
        assert(r1.needsProbe);

        tracker.SetStateForTest(true, "127.0.0.1:7897");
        tracker.SetProbeCallback([](const std::string&, int) -> std::string { return "http"; });
        auto r2 = tracker.GetCurrent(true);
        assert(r2.enabled);
        assert(r2.type == "http");
        assert(!r2.needsProbe);
    }
    std::cout << "All SystemProxyResolver tests passed!" << std::endl;
    return 0;
}

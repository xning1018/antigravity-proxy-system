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
    std::cout << "All SystemProxyResolver tests passed!" << std::endl;
    return 0;
}

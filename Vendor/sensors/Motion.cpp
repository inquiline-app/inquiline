#include "Motion.h"

#include <log/log.h>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

namespace inquiline {

static std::mutex gLock;
static Motion gMotion = {{0.0f, 0.0f, 9.80665f}, {0.0f, 0.0f, 0.0f}};

Motion latestMotion() {
    std::lock_guard<std::mutex> lock(gLock);
    return gMotion;
}

static void serve(int client) {
    float values[6];
    while (true) {
        ssize_t got = recv(client, values, sizeof(values), 0);
        if (got <= 0) break;
        if (got != sizeof(values)) continue;
        std::lock_guard<std::mutex> lock(gLock);
        for (int i = 0; i < 3; i++) {
            gMotion.acceleration[i] = values[i];
            gMotion.rotation[i] = values[3 + i];
        }
    }
    close(client);
}

void startMotionListener() {
    std::thread([] {
        int server = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
        sockaddr_un address = {};
        address.sun_family = AF_UNIX;
        const char name[] = "inquiline-sensors";
        memcpy(address.sun_path + 1, name, sizeof(name) - 1);  // abstract: no file
        socklen_t length = offsetof(sockaddr_un, sun_path) + 1 + sizeof(name) - 1;
        if (server < 0 || bind(server, reinterpret_cast<sockaddr*>(&address), length) != 0 || listen(server, 4) != 0) {
            ALOGE("Inquiline's sensors can't listen for the Mac's motion");
            return;
        }
        while (true) {
            int client = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
            if (client < 0) continue;
            std::thread(serve, client).detach();
        }
    }).detach();
}

}  // namespace inquiline

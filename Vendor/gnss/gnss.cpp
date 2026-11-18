// Android's GPS (an AIDL GNSS HAL, android.hardware.gnss.IGnss/default) that reports where the
// Mac is. Redroid has no GPS, so Android had no location at all; with this one it has a GPS as a
// phone does, and Google Play services' location, which apps ask, works from it.
//
// The fixes come from Inquiline's helper app, which gets them from the Mac (Core Location). The
// helper listens on a socket in its own data folder, which only it and root can reach; this
// service connects to it, says "start <ms>" while Android wants fixes and "stop" when it no
// longer does, and reads lines "fix <lat> <lon> <alt> <hacc> <vacc> <speed> <bearing>" with
// fields of NaN when unknown. Between the Mac's fixes the last one is reported again each
// interval, as a GPS reports each second.
//
// Built by Scripts/vm/build-guest-gnss.sh against the interface's NDK code, which the AIDL
// compiler makes from AOSP's frozen version 3.

#include <aidl/android/hardware/gnss/BnGnss.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <android/log.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

using namespace aidl::android::hardware::gnss;
using ndk::ScopedAStatus;

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "InquilineGnss", __VA_ARGS__)

static const char* kSocket = "/data/data/io.github.inquiline.notifications/files/gnss.sock";

namespace {

int64_t boottimeNs() {
    timespec now;
    clock_gettime(CLOCK_BOOTTIME, &now);
    return int64_t(now.tv_sec) * 1000000000 + now.tv_nsec;
}

int64_t wallMs() {
    timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return int64_t(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
}

class Gnss : public BnGnss {
  public:
    Gnss() { std::thread([this] { helperLoop(); }).detach(); }

    ScopedAStatus setCallback(const std::shared_ptr<IGnssCallback>& callback) override {
        std::lock_guard<std::mutex> lock(mutex_);
        callback_ = callback;
        if (callback_) {
            callback_->gnssSetCapabilitiesCb(IGnssCallback::CAPABILITY_SCHEDULING);
            IGnssCallback::GnssSystemInfo info;
            info.yearOfHw = 2026;
            info.name = "Inquiline (the Mac's location)";
            callback_->gnssSetSystemInfoCb(info);
        }
        return ScopedAStatus::ok();
    }

    ScopedAStatus close() override {
        std::lock_guard<std::mutex> lock(mutex_);
        callback_ = nullptr;
        return ScopedAStatus::ok();
    }

    ScopedAStatus start() override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (running_) return ScopedAStatus::ok();
            running_ = true;
            if (callback_) {
                callback_->gnssStatusCb(IGnssCallback::GnssStatusValue::SESSION_BEGIN);
                callback_->gnssStatusCb(IGnssCallback::GnssStatusValue::ENGINE_ON);
            }
        }
        tellHelper();
        std::thread([this] { reportLoop(); }).detach();
        changed_.notify_all();
        return ScopedAStatus::ok();
    }

    ScopedAStatus stop() override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!running_) return ScopedAStatus::ok();
            running_ = false;
            if (callback_) {
                callback_->gnssStatusCb(IGnssCallback::GnssStatusValue::SESSION_END);
                callback_->gnssStatusCb(IGnssCallback::GnssStatusValue::ENGINE_OFF);
            }
        }
        tellHelper();
        changed_.notify_all();
        return ScopedAStatus::ok();
    }

    ScopedAStatus setPositionMode(const IGnss::PositionModeOptions& options) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            intervalMs_ = std::max(options.minIntervalMs, 1000);
        }
        tellHelper();
        return ScopedAStatus::ok();
    }

    // Nothing else a phone's GPS offers is here: the framework does without each extension.
    ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssConfiguration(std::shared_ptr<IGnssConfiguration>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssMeasurement(std::shared_ptr<IGnssMeasurementInterface>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssPowerIndication(std::shared_ptr<IGnssPowerIndication>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssBatching(std::shared_ptr<IGnssBatching>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssGeofence(std::shared_ptr<IGnssGeofence>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssNavigationMessage(std::shared_ptr<IGnssNavigationMessageInterface>* out) override { return none(out); }
    ScopedAStatus getExtensionAGnss(std::shared_ptr<IAGnss>* out) override { return none(out); }
    ScopedAStatus getExtensionAGnssRil(std::shared_ptr<IAGnssRil>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssDebug(std::shared_ptr<IGnssDebug>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssVisibilityControl(
        std::shared_ptr<visibility_control::IGnssVisibilityControl>* out) override { return none(out); }
    ScopedAStatus getExtensionGnssAntennaInfo(std::shared_ptr<IGnssAntennaInfo>* out) override { return none(out); }
    ScopedAStatus getExtensionMeasurementCorrections(
        std::shared_ptr<measurement_corrections::IMeasurementCorrectionsInterface>* out) override { return none(out); }

    ScopedAStatus injectTime(int64_t, int64_t, int32_t) override { return ScopedAStatus::ok(); }
    ScopedAStatus injectLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
    ScopedAStatus injectBestLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
    ScopedAStatus deleteAidingData(IGnss::GnssAidingData) override { return ScopedAStatus::ok(); }
    ScopedAStatus startSvStatus() override { return ScopedAStatus::ok(); }
    ScopedAStatus stopSvStatus() override { return ScopedAStatus::ok(); }
    ScopedAStatus startNmea() override { return ScopedAStatus::ok(); }
    ScopedAStatus stopNmea() override { return ScopedAStatus::ok(); }

  private:
    template <typename T>
    static ScopedAStatus none(std::shared_ptr<T>* out) {
        *out = nullptr;
        return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }

    /** What Android wants now, to the helper: it asks the Mac only while a fix is wanted. */
    void tellHelper() {
        std::string line;
        int fd;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            fd = helper_;
            line = running_ ? "start " + std::to_string(intervalMs_) + "\n" : "stop\n";
        }
        if (fd >= 0) (void)!write(fd, line.data(), line.size());
    }

    /** Connected to the helper while it runs; its fixes are kept as they come. */
    void helperLoop() {
        while (true) {
            int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
            sockaddr_un address{};
            address.sun_family = AF_UNIX;
            strncpy(address.sun_path, kSocket, sizeof(address.sun_path) - 1);
            if (fd < 0 || connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
                if (fd >= 0) ::close(fd);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                helper_ = fd;
            }
            tellHelper();
            std::string pending;
            char buffer[512];
            ssize_t got;
            while ((got = read(fd, buffer, sizeof(buffer))) > 0) {
                pending.append(buffer, got);
                size_t end;
                while ((end = pending.find('\n')) != std::string::npos) {
                    received(pending.substr(0, end));
                    pending.erase(0, end + 1);
                }
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                helper_ = -1;
            }
            ::close(fd);
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }

    void received(const std::string& line) {
        double v[7];
        if (sscanf(line.c_str(), "fix %lf %lf %lf %lf %lf %lf %lf", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6]) != 7)
            return;
        if (std::isnan(v[0]) || std::isnan(v[1])) return;
        GnssLocation fix;
        fix.gnssLocationFlags = GnssLocation::HAS_LAT_LONG;
        fix.latitudeDegrees = v[0];
        fix.longitudeDegrees = v[1];
        if (!std::isnan(v[2])) { fix.altitudeMeters = v[2]; fix.gnssLocationFlags |= GnssLocation::HAS_ALTITUDE; }
        if (!std::isnan(v[3])) { fix.horizontalAccuracyMeters = v[3]; fix.gnssLocationFlags |= GnssLocation::HAS_HORIZONTAL_ACCURACY; }
        if (!std::isnan(v[4])) { fix.verticalAccuracyMeters = v[4]; fix.gnssLocationFlags |= GnssLocation::HAS_VERTICAL_ACCURACY; }
        if (!std::isnan(v[5])) { fix.speedMetersPerSec = v[5]; fix.gnssLocationFlags |= GnssLocation::HAS_SPEED; }
        if (!std::isnan(v[6])) { fix.bearingDegrees = v[6]; fix.gnssLocationFlags |= GnssLocation::HAS_BEARING; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            last_ = fix;
            haveFix_ = true;
        }
        changed_.notify_all();
    }

    /** While started: the latest fix each interval, stamped now, as a GPS reports. */
    void reportLoop() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (running_) {
            if (haveFix_ && callback_) {
                GnssLocation fix = last_;
                fix.timestampMillis = wallMs();
                fix.elapsedRealtime.flags = ElapsedRealtime::HAS_TIMESTAMP_NS | ElapsedRealtime::HAS_TIME_UNCERTAINTY_NS;
                fix.elapsedRealtime.timestampNs = boottimeNs();
                fix.elapsedRealtime.timeUncertaintyNs = 1000000;
                auto callback = callback_;
                lock.unlock();
                callback->gnssLocationCb(fix);
                lock.lock();
            }
            changed_.wait_for(lock, std::chrono::milliseconds(haveFix_ ? intervalMs_ : 60000));
        }
    }

    std::mutex mutex_;
    std::condition_variable changed_;
    std::shared_ptr<IGnssCallback> callback_;
    bool running_ = false;
    int intervalMs_ = 1000;
    int helper_ = -1;
    bool haveFix_ = false;
    GnssLocation last_;
};

}  // namespace

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(2);
    ABinderProcess_startThreadPool();
    auto gnss = ndk::SharedRefBase::make<Gnss>();
    const std::string name = std::string(Gnss::descriptor) + "/default";
    if (AServiceManager_addService(gnss->asBinder().get(), name.c_str()) != STATUS_OK) {
        LOG("Could not register %s", name.c_str());
        return 1;
    }
    LOG("Ready");
    ABinderProcess_joinThreadPool();
    return 1;
}

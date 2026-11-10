// Part of Inquiline's scrcpy server build (see Vendor/scrcpy-server.patch): tells which
// virtio-gpu resource holds an Android buffer, so the Mac can have gfxstream copy that
// resource's pixels straight into the window's memory instead of receiving a video stream.
#include <dlfcn.h>
#include <fcntl.h>
#include <jni.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <android/hardware_buffer_jni.h>
#include <drm.h>
#include <virtgpu_drm.h>

typedef struct {
    int version;
    int numFds;
    int numInts;
    int data[0];
} native_handle_t;

// From libnativewindow, which apps can't link but app_process may load.
typedef const native_handle_t *(*GetNativeHandle)(const AHardwareBuffer *);

static int gpu = -1;
static GetNativeHandle getNativeHandle;

// The resource id, or 0 when the buffer isn't a virtio-gpu resource.
JNIEXPORT jint JNICALL
Java_com_genymobile_scrcpy_video_FrameStreamer_resourceId(JNIEnv *env, jclass cls, jobject buffer) {
    if (gpu < 0) {
        gpu = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
        void *library = dlopen("libnativewindow.so", RTLD_NOW);
        if (library) getNativeHandle = (GetNativeHandle) dlsym(library, "AHardwareBuffer_getNativeHandle");
    }
    if (gpu < 0 || !getNativeHandle) return 0;
    AHardwareBuffer *hardwareBuffer = AHardwareBuffer_fromHardwareBuffer(env, buffer);
    const native_handle_t *handle = hardwareBuffer ? getNativeHandle(hardwareBuffer) : NULL;
    if (!handle || handle->numFds < 1) return 0;

    struct drm_prime_handle prime = {.fd = handle->data[0]};
    if (ioctl(gpu, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) != 0) return 0;
    struct drm_virtgpu_resource_info info = {.bo_handle = prime.handle};
    int found = ioctl(gpu, DRM_IOCTL_VIRTGPU_RESOURCE_INFO, &info) == 0;
    struct drm_gem_close close = {.handle = prime.handle};
    ioctl(gpu, DRM_IOCTL_GEM_CLOSE, &close);
    return found ? (jint) info.res_handle : 0;
}

#include <Hypervisor/Hypervisor.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>

// QEMU returns the memory Android frees with MADV_DONTNEED, which macOS ignores: the
// process keeps the memory. So that call is replaced for guest RAM: unmapping the range
// from the VM, replacing it with fresh memory and mapping it back really frees it. The
// guest has given these pages up, so it can't touch them meanwhile and expects no contents.
typedef struct {
    void *host;
    hv_ipa_t guest;
    size_t size;
    hv_memory_flags_t flags;
} Mapping;

#define MAX_MAPPINGS 64
static Mapping mappings[MAX_MAPPINGS];
static pthread_mutex_t mappingsLock = PTHREAD_MUTEX_INITIALIZER;

static hv_return_t mapGuest(void *host, hv_ipa_t guest, size_t size, hv_memory_flags_t flags) {
    hv_return_t result = hv_vm_map(host, guest, size, flags);
    if (result != HV_SUCCESS) return result;
    pthread_mutex_lock(&mappingsLock);
    for (int i = 0; i < MAX_MAPPINGS; i++) {
        if (mappings[i].size == 0) {
            mappings[i] = (Mapping){host, guest, size, flags};
            break;
        }
    }
    pthread_mutex_unlock(&mappingsLock);
    return result;
}

static hv_return_t unmapGuest(hv_ipa_t guest, size_t size) {
    hv_return_t result = hv_vm_unmap(guest, size);
    if (result != HV_SUCCESS) return result;
    pthread_mutex_lock(&mappingsLock);
    for (int i = 0; i < MAX_MAPPINGS; i++) {
        if (mappings[i].guest == guest && mappings[i].size == size) mappings[i].size = 0;
    }
    pthread_mutex_unlock(&mappingsLock);
    return result;
}

static int releaseMemory(void *address, size_t length, int advice) {
    if (advice != MADV_DONTNEED) return madvise(address, length, advice);

    int result = -1;
    int found = 0;
    pthread_mutex_lock(&mappingsLock);
    for (int i = 0; i < MAX_MAPPINGS && !found; i++) {
        Mapping *mapping = &mappings[i];
        char *start = mapping->host;
        if (mapping->size == 0 || (char *)address < start || (char *)address + length > start + mapping->size) continue;
        found = 1;
        hv_ipa_t guest = mapping->guest + ((char *)address - start);
        if (hv_vm_unmap(guest, length) != HV_SUCCESS) break;
        void *fresh = mmap(address, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        // Without its memory the guest would crash. Failing here is not expected.
        if (fresh != address || hv_vm_map(address, guest, length, mapping->flags) != HV_SUCCESS) abort();
        result = 0;
    }
    pthread_mutex_unlock(&mappingsLock);
    return found ? result : madvise(address, length, advice);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} interposers[] = {
    {mapGuest, hv_vm_map},
    {unmapGuest, hv_vm_unmap},
    {releaseMemory, madvise},
};

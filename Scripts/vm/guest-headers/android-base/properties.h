// Inquiline: the one libbase call the gfxstream driver makes, on bionic's property API.
#pragma once
#include <string>
#include <sys/system_properties.h>
namespace android { namespace base {
inline std::string GetProperty(const std::string& key, const std::string& fallback) {
    char value[PROP_VALUE_MAX] = {};
    return __system_property_get(key.c_str(), value) > 0 ? std::string(value) : fallback;
}
} }

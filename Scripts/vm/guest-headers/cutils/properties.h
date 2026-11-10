// Inquiline: libcutils' property_get on bionic's property API.
#pragma once
#include <string.h>
#include <sys/system_properties.h>
#define PROPERTY_VALUE_MAX PROP_VALUE_MAX
static inline int property_get(const char* key, char* value, const char* fallback) {
    int n = __system_property_get(key, value);
    if (n > 0) return n;
    if (fallback) { strcpy(value, fallback); return (int)strlen(fallback); }
    value[0] = 0;
    return 0;
}

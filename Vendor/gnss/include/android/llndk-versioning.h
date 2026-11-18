// Stand-in for bionic's android/llndk-versioning.h, which the NDK leaves out: the service is
// built for Android 15, which has every function these headers mark.
#pragma once
#define __INTRODUCED_IN_LLNDK(x)

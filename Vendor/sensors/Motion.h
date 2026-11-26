/*
 * Inquiline: the motion Android's sensors report, as the Mac sends it: a game controller's or a
 * phone's, calibrated on the Mac (SDLGamepads, GamepadMotionHelpers). Each packet on the
 * abstract socket "inquiline-sensors" (SOCK_SEQPACKET), which the scrcpy server sends a window's
 * motion to, is six little-endian floats: acceleration x, y, z in m/s² with gravity, then
 * rotation x, y, z in rad/s, in Android's axes for the window's display. With none, the device
 * lies still on its back, as a phone on a table.
 */
#pragma once

namespace inquiline {

struct Motion {
    float acceleration[3];
    float rotation[3];
};

// The latest motion; safe from any thread.
Motion latestMotion();

// Listens for the Mac's motion on its own thread.
void startMotionListener();

}  // namespace inquiline

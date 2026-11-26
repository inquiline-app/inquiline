// A controller's motion, calibrated by GamepadMotionHelpers (Vendor/gamepad-motion, MIT): its
// gyro's bias found and taken away while it rests, as JoyShockMapper and Steam do.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct InquilineMotion InquilineMotion;

InquilineMotion *inquiline_motion_create(void);
void inquiline_motion_destroy(InquilineMotion *motion);
/// One sample: rotation in rad/s and acceleration in m/s² (SDL's units and axes), `seconds`
/// after the last. Gives the rotation with the gyro's bias taken away, in rad/s.
void inquiline_motion_process(InquilineMotion *motion, const float rotation[3], const float acceleration[3],
                              float seconds, float calibrated[3]);
/// How far the controller is turned like a steering wheel, in radians, right positive: from the
/// gravity GamepadMotionHelpers follows with the gyro and the accelerometer together.
float inquiline_motion_roll(InquilineMotion *motion);

#ifdef __cplusplus
}
#endif

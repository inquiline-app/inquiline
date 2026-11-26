#include "CMotion.h"
#include "GamepadMotion.hpp"
#include <math.h>

static const float kDegrees = 57.29577951308232f;
static const float kGravity = 9.80665f;

struct InquilineMotion {
    GamepadMotion motion;
};

InquilineMotion *inquiline_motion_create(void) {
    auto *made = new InquilineMotion();
    // Found again whenever the controller rests, and from the accelerometer while it moves.
    made->motion.SetCalibrationMode(GamepadMotionHelpers::Stillness | GamepadMotionHelpers::SensorFusion);
    return made;
}

void inquiline_motion_destroy(InquilineMotion *motion) { delete motion; }

void inquiline_motion_process(InquilineMotion *motion, const float rotation[3], const float acceleration[3],
                              float seconds, float calibrated[3]) {
    motion->motion.ProcessMotion(rotation[0] * kDegrees, rotation[1] * kDegrees, rotation[2] * kDegrees,
                                 acceleration[0] / kGravity, acceleration[1] / kGravity, acceleration[2] / kGravity,
                                 seconds);
    float x, y, z;
    motion->motion.GetCalibratedGyro(x, y, z);
    calibrated[0] = x / kDegrees;
    calibrated[1] = y / kDegrees;
    calibrated[2] = z / kDegrees;
}

float inquiline_motion_roll(InquilineMotion *motion) {
    float x, y, z;
    motion->motion.GetGravity(x, y, z);
    // Gravity points down: turned right, the controller's right side drops toward it.
    return atan2f(x, sqrtf(y * y + z * z));
}

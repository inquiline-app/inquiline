import CoreLocation
import Foundation

/// Where the Mac is, for Android's GPS (Vendor/gnss): as a phone's GPS is on only while an app
/// wants to know where it is, Core Location runs only while Android asks for fixes, which the
/// helper says (NotificationBridge). The first time, the Mac asks the user, in its own words, as
/// a phone asks for an app; without leave, Android gets no fixes and its apps see no location.
final class LocationBridge: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBridge()

    /// Sends a message to the helper inside Android.
    var send: (([String: Any]) -> Void)?

    private let manager = CLLocationManager()
    private var wanted = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Android wants fixes, or no longer does; on the main thread.
    func set(wanted: Bool) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        if wanted {
            AppLog.write("Android asks where the Mac is")
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            manager.startUpdatingLocation()
            // The last fix, at once, while Core Location finds a new one, as a phone's GPS
            // starts from where it last was.
            if let last = manager.location { forward(last) }
        } else {
            AppLog.write("Android no longer asks where the Mac is")
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if wanted, let last = locations.last { forward(last) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Not allowed, or not found yet: Android gets nothing, as a phone without a fix.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wanted, manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    /// Only the fix goes to Android, never to the log.
    private func forward(_ location: CLLocation) {
        var fix: [String: Any] = ["lat": location.coordinate.latitude, "lon": location.coordinate.longitude]
        if location.horizontalAccuracy >= 0 { fix["hacc"] = location.horizontalAccuracy }
        if location.verticalAccuracy > 0 {
            fix["alt"] = location.altitude
            fix["vacc"] = location.verticalAccuracy
        }
        if location.speed >= 0 { fix["speed"] = location.speed }
        if location.course >= 0 { fix["bearing"] = location.course }
        send?(["location": fix])
    }
}

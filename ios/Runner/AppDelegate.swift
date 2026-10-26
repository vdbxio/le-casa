import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LeCasaTablet") {
      TabletChannel.register(messenger: registrar.messenger())
    }
  }
}

/// The iPad side of lib/platform/tablet.dart, matching MainActivity.kt:
/// battery, screen brightness and keep-screen-on. iPads have no public
/// ambient light API, so the light stream reports that at once.
enum TabletChannel {
  /// The system brightness before the app dimmed the screen. iOS
  /// brightness is system-wide, so handing it back means restoring this.
  private static var savedBrightness: CGFloat?

  static func register(messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: "io.vdbx.lecasa/tablet", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in
      switch call.method {
      case "battery":
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        result([
          "level": level < 0 ? NSNull() : NSNumber(value: Int((level * 100).rounded())),
          "charging": device.batteryState == .charging || device.batteryState == .full,
        ])
      case "setBrightness":
        let screen = UIScreen.main
        if let value = call.arguments as? Double {
          if savedBrightness == nil { savedBrightness = screen.brightness }
          screen.brightness = CGFloat(value)
        } else if let saved = savedBrightness {
          screen.brightness = saved
          savedBrightness = nil
        }
        result(nil)
      case "deviceName":
        // "iPad" or "iPhone": iOS keeps the name the owner gave the device
        // from apps without a special entitlement.
        result(UIDevice.current.model)
      case "keepScreenOn":
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: "io.vdbx.lecasa/light", binaryMessenger: messenger)
      .setStreamHandler(NoLightSensor())
  }
}

private class NoLightSensor: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    return FlutterError(
      code: "no_sensor", message: "iPads have no ambient light sensor the app can read",
      details: nil)
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}

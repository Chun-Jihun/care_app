import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CarePrivacy") else { return }
    let channel = FlutterMethodChannel(name: "org.carenotebook/privacy", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "protectDirectory":
        guard let path = arguments["path"] as? String,
              path.hasPrefix(NSHomeDirectory() + "/Library/") else {
          result(FlutterError(code: "path", message: "저장소 위치를 확인할 수 없습니다.", details: nil)); return
        }
        do {
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues(); values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
          result(nil)
        } catch { result(FlutterError(code: "protection", message: "보안 저장소를 준비할 수 없습니다.", details: nil)) }
      case "timeZone": result(TimeZone.current.identifier)
      case "dial":
        guard let number = arguments["number"] as? String,
              number.range(of: "^[+0-9 ()-]{2,32}$", options: .regularExpression) != nil,
              let url = URL(string: "tel:" + number.filter { "+0123456789".contains($0) }) else {
          result(FlutterError(code: "number", message: "연락처를 확인해 주세요.", details: nil)); return
        }
        UIApplication.shared.open(url) { success in
          result(success ? nil : FlutterError(code: "dial", message: "전화 화면을 열 수 없습니다.", details: nil))
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

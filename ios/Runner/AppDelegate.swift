import Flutter
import UIKit

/// Adds ONE thing to the stock app delegate: the payment deep link.
///
/// INTERFACES.md §7. The backend verifies the payment server-side and then 302s the
/// browser to `irallymeter://payment/callback?...`. iOS matches that against
/// `CFBundleURLTypes` in Info.plist and hands it to `application(_:open:options:)`.
///
/// ⚠ The link is a WAKE-UP SIGNAL ONLY. Nothing in it is trusted: Dart re-reads
/// `/membership` on arrival, because SPEC.md §4 makes the backend the sole authority on
/// whether a payment succeeded, and a URL a browser handed us is not evidence.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let channelName = "irallymeter/deeplink"
  private static let scheme = "irallymeter"

  private var channel: FlutterMethodChannel?

  /// A link that arrived before Dart was listening. Collected by `consumeInitialLink`
  /// so the race between a cold launch and the first Dart frame cannot drop it.
  private var pendingLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Cold start: the app was not running and the link is what launched it. Reachable
    // when iOS reclaimed the app while the user was at the payment gateway.
    if let url = launchOptions?[.url] as? URL, url.scheme == AppDelegate.scheme {
      pendingLink = url.absoluteString
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The messenger comes from a registrar rather than from the view controller: at this
    // point the engine exists but the root view controller may not, and reaching for
    // `window?.rootViewController` here returns nil on a cold launch.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IRallyMeterDeepLink")
    else { return }

    let channel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "consumeInitialLink" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Consumed, not merely read: replaying it on a later hot restart would re-run the
      // post-payment flow for a payment already handled.
      let link = self?.pendingLink
      self?.pendingLink = nil
      result(link)
    }
    self.channel = channel
  }

  /// The normal path: the app is already running and iOS reopens it with the URL.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.scheme == AppDelegate.scheme else {
      return super.application(app, open: url, options: options)
    }
    if let channel = channel {
      channel.invokeMethod("link", arguments: url.absoluteString)
    } else {
      // Engine not configured yet. Hold it rather than dropping it.
      pendingLink = url.absoluteString
    }
    return true
  }
}

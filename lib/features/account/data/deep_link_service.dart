import 'dart:async';

import 'package:flutter/services.dart';

/// What the payment deep link said.
///
/// ⚠ **None of this is evidence.** `INTERFACES.md` §7: the link is *"a wake-up signal
/// only"*. The app's response to any of it is the same — ask the server. It is modelled
/// as a type rather than passed around as a raw string so that a future caller cannot
/// accidentally branch on `result=success` and skip the check.
class PaymentCallback {
  const PaymentCallback({required this.claimsSuccess, this.paymentId});

  /// What the *link* claimed. Named to make the caller uncomfortable about trusting it.
  final bool claimsSuccess;

  final String? paymentId;

  /// Parses `irallymeter://payment/callback?paymentId=…&result=success|failed`.
  static PaymentCallback? tryParse(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'irallymeter' || uri.host != 'payment') return null;
    return PaymentCallback(
      claimsSuccess: uri.queryParameters['result'] == 'success',
      paymentId: uri.queryParameters['paymentId'],
    );
  }
}

/// Receives `irallymeter://` links from the platform.
///
/// The native halves are `MainActivity.kt` (Android) and `AppDelegate.swift` (iOS);
/// both are new files/additions, and neither touches any GPS or rally code.
///
/// ⚠ **Two arrival paths, and the race between them is the whole reason this class
/// holds state.** A link can arrive while the app is running (`link` is invoked on the
/// channel) or as the thing that launched a cold process (held natively and collected by
/// `consumeInitialLink`). Listening only to the stream drops the cold-start case; asking
/// only for the initial link drops the common case.
class DeepLinkService {
  DeepLinkService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('irallymeter/deeplink') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<PaymentCallback> _controller =
      StreamController<PaymentCallback>.broadcast();

  Stream<PaymentCallback> get callbacks => _controller.stream;

  /// The link that launched the app, if any. Consumed on the native side, so calling it
  /// twice returns null the second time — a replay would re-run the post-payment flow
  /// for a payment already handled.
  Future<PaymentCallback?> consumeInitialLink() async {
    try {
      final String? raw =
          await _channel.invokeMethod<String>('consumeInitialLink');
      return raw == null ? null : PaymentCallback.tryParse(raw);
    } on MissingPluginException {
      // No native half — a widget test, or a platform we do not ship. Not an error:
      // there simply is no link.
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'link') return null;
    final Object? raw = call.arguments;
    if (raw is! String) return null;
    final PaymentCallback? parsed = PaymentCallback.tryParse(raw);
    // A link we cannot parse is dropped rather than surfaced. Anything reaching here
    // that is not our own callback is not ours to act on.
    if (parsed != null) _controller.add(parsed);
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}

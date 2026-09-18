package com.irallyclub.irallymeter

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds ONE thing to the stock FlutterActivity: the payment deep link.
 *
 * INTERFACES.md §7. The backend verifies the payment server-side and then 302s the
 * browser to `irallymeter://payment/callback?...`. Android resolves that against the
 * intent-filter in AndroidManifest.xml and delivers it here.
 *
 * ⚠ The link is a WAKE-UP SIGNAL ONLY. Nothing in it is trusted: Dart re-reads
 * `/membership` on arrival, because SPEC.md §4 says the backend is the sole authority
 * on whether a payment succeeded and a URL a browser handed us is not evidence.
 *
 * ⚠ TWO ARRIVAL PATHS, and both are real:
 *   · `onNewIntent` — the normal one. This activity is `launchMode="singleTop"`, so a
 *     link arriving while the app is alive reuses the existing activity.
 *   · the launch intent — reachable when Android killed the app while the user was at
 *     the gateway, so the link starts a cold process instead.
 * A link that arrives before Dart is listening is held in `pendingLink` and collected
 * by `consumeInitialLink`, so it cannot be dropped in the race between the two.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The cold-start link, captured BEFORE the handler is installed so it cannot be
        // missed by a Dart side that has not started listening yet.
        intent?.dataString?.let { if (it.startsWith(SCHEME)) pendingLink = it }

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialLink" -> {
                        // Consumed, not merely read: replaying it on a later hot restart
                        // would re-run the post-payment flow for a payment already
                        // handled.
                        val link = pendingLink
                        pendingLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = intent.dataString ?: return
        if (!link.startsWith(SCHEME)) return

        val open = channel
        if (open == null) {
            // The engine is not configured yet. Hold it rather than dropping it.
            pendingLink = link
        } else {
            open.invokeMethod("link", link)
        }
    }

    private companion object {
        const val CHANNEL = "irallymeter/deeplink"
        const val SCHEME = "irallymeter://"
    }
}

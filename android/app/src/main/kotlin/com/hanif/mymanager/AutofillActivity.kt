package com.hanif.mymanager

import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * অন্য অ্যাপের (Chrome, Facebook...) লগইন ফর্মের উপর দিয়ে খুলবে এমন আলাদা
 * Activity। উইন্ডো স্বচ্ছ (AutofillTheme + transparent background mode),
 * তাই Flutter-এর কার্ডটা নিচ থেকে উঠে আসা শিটের মতো দেখায়।
 *
 * FlutterFragmentActivity লাগে কারণ picker-এ local_auth-এর
 * ফিঙ্গারপ্রিন্ট/PIN প্রম্পট আছে।
 */
class AutofillActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WindowFlags.register(flutterEngine, this)
    }

    override fun getDartEntrypointFunctionName(): String = "autofillEntryPoint"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent
}

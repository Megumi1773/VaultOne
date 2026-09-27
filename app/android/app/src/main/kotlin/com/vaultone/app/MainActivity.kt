package com.vaultone.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import android.view.autofill.AutofillManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity：local_auth（BiometricPrompt）要求宿主为 FragmentActivity。
 * FLAG_SECURE：禁止截屏/录屏，并在最近任务界面隐藏内容（计划书 F-10）。
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    /** `vaultone/platform`：设置页查询 / 开启系统自动填充服务。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vaultone/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "autofillSupported" -> result.success(autofillManager()?.isAutofillSupported == true)
                "autofillEnabled" -> result.success(autofillManager()?.hasEnabledAutofillServices() == true)
                "openAutofillSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).setData(Uri.parse("package:$packageName"))
                        runCatching { startActivity(intent) }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun autofillManager(): AutofillManager? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) getSystemService(AutofillManager::class.java) else null
}

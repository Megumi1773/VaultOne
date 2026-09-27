package com.vaultone.app.autofill

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.vaultone.app.R
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 自动填充的 Flutter 界面宿主。运行 Dart 入口 `autofillMain`（见 lib/main.dart），通过 `vaultone/autofill`
 * 通道取得请求信息，并在用户选定条目后把用户名 / 密码作为认证结果（Dataset）交回系统。
 * FlutterFragmentActivity：解锁时 local_auth 需要 FragmentActivity。
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun getDartEntrypointFunctionName() = "autofillMain"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> result.success(
                    mapOf(
                        "mode" to intent.getStringExtra(EXTRA_MODE),
                        "webDomain" to intent.getStringExtra(EXTRA_DOMAIN),
                        "pageUrl" to intent.getStringExtra(EXTRA_URL),
                        "packageName" to intent.getStringExtra(EXTRA_PACKAGE),
                        "username" to intent.getStringExtra(EXTRA_USERNAME),
                        "password" to intent.getStringExtra(EXTRA_PASSWORD),
                    ),
                )
                "fill" -> {
                    result.success(null)
                    finishWithDataset(
                        call.argument<String>("username").orEmpty(),
                        call.argument<String>("password").orEmpty(),
                        call.argument<String>("title").orEmpty(),
                    )
                }
                "cancel" -> {
                    result.success(null)
                    setResult(Activity.RESULT_CANCELED)
                    finish()
                }
                "done" -> {
                    result.success(null)
                    setResult(Activity.RESULT_OK)
                    finish()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ids(key: String): List<AutofillId> =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(key, AutofillId::class.java).orEmpty()
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<AutofillId>(key).orEmpty()
        }

    private fun finishWithDataset(username: String, password: String, title: String) {
        val presentation = RemoteViews(packageName, R.layout.autofill_item).apply { setTextViewText(R.id.autofill_text, title) }
        val dataset = Dataset.Builder(presentation)
        var any = false
        if (username.isNotEmpty()) ids(EXTRA_USERNAME_IDS).forEach { dataset.setValue(it, AutofillValue.forText(username)); any = true }
        if (password.isNotEmpty()) ids(EXTRA_PASSWORD_IDS).forEach { dataset.setValue(it, AutofillValue.forText(password)); any = true }
        if (!any) {
            setResult(Activity.RESULT_CANCELED)
        } else {
            setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset.build()))
        }
        finish()
    }

    companion object {
        private const val CHANNEL = "vaultone/autofill"
        private const val EXTRA_MODE = "vaultone.mode"
        private const val EXTRA_DOMAIN = "vaultone.domain"
        private const val EXTRA_URL = "vaultone.url"
        private const val EXTRA_PACKAGE = "vaultone.package"
        private const val EXTRA_USERNAME = "vaultone.username"
        private const val EXTRA_PASSWORD = "vaultone.password"
        private const val EXTRA_USERNAME_IDS = "vaultone.usernameIds"
        private const val EXTRA_PASSWORD_IDS = "vaultone.passwordIds"

        fun fillIntent(context: Context, p: ParsedStructure): Intent = Intent(context, AutofillActivity::class.java)
            .putExtra(EXTRA_MODE, "fill")
            .putExtra(EXTRA_DOMAIN, p.webDomain)
            .putExtra(EXTRA_URL, p.pageUrl)
            .putExtra(EXTRA_PACKAGE, p.packageName)
            .putParcelableArrayListExtra(EXTRA_USERNAME_IDS, ArrayList(p.usernameIds))
            .putParcelableArrayListExtra(EXTRA_PASSWORD_IDS, ArrayList(p.passwordIds))

        fun saveIntent(context: Context, p: ParsedStructure): Intent = Intent(context, AutofillActivity::class.java)
            .putExtra(EXTRA_MODE, "save")
            .putExtra(EXTRA_DOMAIN, p.webDomain)
            .putExtra(EXTRA_URL, p.pageUrl)
            .putExtra(EXTRA_PACKAGE, p.packageName)
            .putExtra(EXTRA_USERNAME, p.usernameValue)
            .putExtra(EXTRA_PASSWORD, p.passwordValue)
    }
}

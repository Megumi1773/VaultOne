package com.vaultone.app.autofill

import android.app.PendingIntent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.vaultone.app.R

/**
 * VaultOne 自动填充服务（计划书 F-05：Android AutofillService）。
 *
 * 服务本身**不接触任何凭据**：它只识别表单字段，返回一个"需要认证"的响应。用户点选「用 VaultOne 填充」后，
 * 系统启动 [AutofillActivity]（Flutter 界面，必要时先解锁），由用户选择条目后才生成填充数据集。
 * 网页表单的域名交给 Rust 内核做 eTLD+1 严格匹配；应用内表单不做自动匹配，由用户搜索选择（防恶意应用冒充）。
 */
@RequiresApi(Build.VERSION_CODES.O)
class VaultAutofillService : AutofillService() {

    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return callback.onSuccess(null)
        val parsed = StructureParser.parse(structure)
        if (parsed.isEmpty || parsed.packageName == packageName) return callback.onSuccess(null)

        val sender = PendingIntent.getActivity(
            this,
            REQUEST_FILL,
            AutofillActivity.fillIntent(this, parsed),
            // 系统会往 Intent 里附加 EXTRA_ASSIST_STRUCTURE，必须可变
            PendingIntent.FLAG_CANCEL_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
        ).intentSender

        val response = FillResponse.Builder()
            .setAuthentication(parsed.allIds.toTypedArray(), sender, presentation(getString(R.string.autofill_fill_with)))
        if (parsed.passwordIds.isNotEmpty()) {
            val save = SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD, parsed.passwordIds.toTypedArray())
            if (parsed.usernameIds.isNotEmpty()) save.setOptionalIds(parsed.usernameIds.toTypedArray())
            response.setSaveInfo(save.build())
        }
        callback.onSuccess(response.build())
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return callback.onFailure(null)
        val parsed = StructureParser.parse(structure)
        if (parsed.passwordValue.isNullOrEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return callback.onSuccess()
        }
        // Android 9+：由 VaultOne 界面确认后再加密写入
        val sender = PendingIntent.getActivity(
            this,
            REQUEST_SAVE,
            AutofillActivity.saveIntent(this, parsed),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ).intentSender
        callback.onSuccess(sender)
    }

    private fun presentation(text: String) = RemoteViews(packageName, R.layout.autofill_item).apply {
        setTextViewText(R.id.autofill_text, text)
    }

    companion object {
        private const val REQUEST_FILL = 1001
        private const val REQUEST_SAVE = 1002
    }
}

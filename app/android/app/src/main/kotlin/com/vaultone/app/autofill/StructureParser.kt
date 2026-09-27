package com.vaultone.app.autofill

import android.app.assist.AssistStructure
import android.os.Build
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import androidx.annotation.RequiresApi

/**
 * 从 AssistStructure 中识别出的登录表单。
 */
@RequiresApi(Build.VERSION_CODES.O)
class ParsedStructure(
    /** 网页域名（浏览器 / WebView 提供），应用内表单为 null */
    val webDomain: String?,
    val webScheme: String?,
    val packageName: String,
    val usernameIds: List<AutofillId>,
    val passwordIds: List<AutofillId>,
    /** 保存请求时用户已输入的值 */
    val usernameValue: String?,
    val passwordValue: String?,
) {
    val isEmpty get() = usernameIds.isEmpty() && passwordIds.isEmpty()
    val allIds get() = usernameIds + passwordIds

    /** 交给内核做防钓鱼匹配的页面地址（仅网页表单有）。 */
    val pageUrl: String?
        get() = webDomain?.let { "${if (webScheme == "http") "http" else "https"}://$it" }
}

/**
 * 从 AssistStructure 中找出用户名 / 密码输入框（计划书 F-05 Android AutofillService）。
 *
 * 判定顺序：autofillHints → HTML 属性（浏览器兼容模式 / WebView）→ inputType → id / hint 文本关键词。
 * 找到密码框但没有明确的用户名框时，取密码框之前最近的一个可编辑文本框。
 */
@RequiresApi(Build.VERSION_CODES.O)
object StructureParser {
    private val USER_WORDS = Regex("user|login|email|e-mail|account|phone|mobile|账号|帐号|用户名|邮箱|手机", RegexOption.IGNORE_CASE)
    private val PASS_WORDS = Regex("pass|pwd|密码", RegexOption.IGNORE_CASE)
    private val OTP_WORDS = Regex("otp|totp|2fa|code|验证码", RegexOption.IGNORE_CASE)

    private class Field(val id: AutofillId, val kind: Kind, val value: String?)
    private enum class Kind { USERNAME, PASSWORD, TEXT }

    fun parse(structure: AssistStructure): ParsedStructure {
        val fields = mutableListOf<Field>()
        var domain: String? = null
        var scheme: String? = null
        for (i in 0 until structure.windowNodeCount) {
            walk(structure.getWindowNodeAt(i).rootViewNode, fields) { d, s ->
                if (domain == null && !d.isNullOrBlank()) {
                    domain = d
                    scheme = s
                }
            }
        }
        var users = fields.filter { it.kind == Kind.USERNAME }
        val passwords = fields.filter { it.kind == Kind.PASSWORD }
        if (users.isEmpty() && passwords.isNotEmpty()) {
            val firstPw = fields.indexOf(passwords.first())
            fields.subList(0, firstPw).lastOrNull { it.kind == Kind.TEXT }?.let { users = listOf(it) }
        }
        return ParsedStructure(
            webDomain = domain,
            webScheme = scheme,
            packageName = structure.activityComponent.packageName,
            usernameIds = users.map { it.id },
            passwordIds = passwords.map { it.id },
            usernameValue = users.firstNotNullOfOrNull { it.value?.takeIf(String::isNotEmpty) },
            passwordValue = passwords.firstNotNullOfOrNull { it.value?.takeIf(String::isNotEmpty) },
        )
    }

    private fun walk(node: AssistStructure.ViewNode, out: MutableList<Field>, onDomain: (String?, String?) -> Unit) {
        val scheme = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) node.webScheme else null
        onDomain(node.webDomain, scheme)
        classify(node)?.let { kind ->
            node.autofillId?.let { out.add(Field(it, kind, node.autofillValue?.takeIf { v -> v.isText }?.textValue?.toString())) }
        }
        for (i in 0 until node.childCount) walk(node.getChildAt(i), out, onDomain)
    }

    private fun classify(node: AssistStructure.ViewNode): Kind? {
        if (node.autofillType != View.AUTOFILL_TYPE_TEXT || node.visibility != View.VISIBLE) return null
        if (node.importantForAutofill == View.IMPORTANT_FOR_AUTOFILL_NO) return null
        node.autofillHints?.forEach { hint ->
            when {
                hint.contains("password", ignoreCase = true) -> return Kind.PASSWORD
                hint.contains("username", ignoreCase = true) || hint.contains("email", ignoreCase = true) -> return Kind.USERNAME
                hint.contains("otp", ignoreCase = true) || hint.contains("oneTimeCode", ignoreCase = true) -> return null
            }
        }
        node.htmlInfo?.attributes?.forEach { attr ->
            if (attr.first == "type") {
                when (attr.second?.lowercase()) {
                    "password" -> return Kind.PASSWORD
                    "email" -> return Kind.USERNAME
                }
            }
        }
        val variation = node.inputType and InputType.TYPE_MASK_VARIATION
        val klass = node.inputType and InputType.TYPE_MASK_CLASS
        val textPassword = setOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
        )
        val textEmail = setOf(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)
        if (klass == InputType.TYPE_CLASS_TEXT && variation in textPassword) return Kind.PASSWORD
        if (klass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) return Kind.PASSWORD
        if (klass == InputType.TYPE_CLASS_TEXT && variation in textEmail) return Kind.USERNAME
        val text = listOfNotNull(node.idEntry, node.hint, node.contentDescription?.toString()).joinToString(" ")
        return when {
            OTP_WORDS.containsMatchIn(text) -> null
            PASS_WORDS.containsMatchIn(text) -> Kind.PASSWORD
            USER_WORDS.containsMatchIn(text) -> Kind.USERNAME
            klass == InputType.TYPE_CLASS_TEXT || node.className?.endsWith("EditText") == true -> Kind.TEXT
            else -> null
        }
    }
}

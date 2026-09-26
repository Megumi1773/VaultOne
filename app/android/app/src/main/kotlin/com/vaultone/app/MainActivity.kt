package com.vaultone.app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * FlutterFragmentActivity：local_auth（BiometricPrompt）要求宿主为 FragmentActivity。
 * FLAG_SECURE：禁止截屏/录屏，并在最近任务界面隐藏内容（计划书 F-10）。
 */
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
}

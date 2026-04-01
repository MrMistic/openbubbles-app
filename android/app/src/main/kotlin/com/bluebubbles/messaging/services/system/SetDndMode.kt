package com.bluebubbles.messaging.services.system

import android.app.NotificationManager
import android.content.Context
import android.provider.Settings
import android.util.Log
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SetDndMode: MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-dnd-mode"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val enabled: Boolean = call.argument("enabled") ?: false

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!notificationManager.isNotificationPolicyAccessGranted) {
            Log.w("OpenBubbles", "Cannot set DND mode: notification policy access not granted")
            result.success(false)
            return
        }

        if (hasWriteSecureSettings(context)) {
            // Enhanced mode: directly control global zen_mode
            try {
                val zenMode = if (enabled) 1 else 0 // 1 = Priority Only, 0 = Off
                Settings.Global.putInt(context.contentResolver, "zen_mode", zenMode)
                Log.i("OpenBubbles", "Focus sync: set global zen_mode=$zenMode")
                result.success(true)
                return
            } catch (e: Exception) {
                Log.w("OpenBubbles", "Failed to set global zen_mode, falling back: ${e.message}")
            }
        }

        // Fallback: app-managed DND (creates "Do Not Disturb (OpenBubbles)" mode)
        val filter = if (enabled) {
            NotificationManager.INTERRUPTION_FILTER_PRIORITY
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }
        notificationManager.setInterruptionFilter(filter)
        Log.i("OpenBubbles", "Focus sync: set DND mode enabled=$enabled (app-managed)")
        result.success(true)
    }

    private fun hasWriteSecureSettings(context: Context): Boolean {
        return try {
            context.checkCallingOrSelfPermission("android.permission.WRITE_SECURE_SETTINGS") ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (e: Exception) {
            false
        }
    }
}

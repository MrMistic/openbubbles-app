package com.bluebubbles.messaging.services.system

import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SetDndMode: MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-dnd-mode"
        private const val RULE_NAME = "Focus Status"
        private const val RULE_ID_PREF = "focus_status_zen_rule_id"
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
                val zenMode = if (enabled) 1 else 0
                Settings.Global.putInt(context.contentResolver, "zen_mode", zenMode)
                Log.i("OpenBubbles", "Focus sync: set global zen_mode=$zenMode")
                result.success(true)
                return
            } catch (e: Exception) {
                Log.w("OpenBubbles", "Failed to set global zen_mode, falling back: ${e.message}")
            }
        }

        // Fallback: use an explicit AutomaticZenRule named "Focus Status"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (enabled) {
                enableFocusStatusRule(context, notificationManager)
            } else {
                disableFocusStatusRule(context, notificationManager)
            }
        } else {
            val filter = if (enabled) {
                NotificationManager.INTERRUPTION_FILTER_PRIORITY
            } else {
                NotificationManager.INTERRUPTION_FILTER_ALL
            }
            notificationManager.setInterruptionFilter(filter)
        }

        Log.i("OpenBubbles", "Focus sync: set DND mode enabled=$enabled (app-managed)")
        result.success(true)
    }

    private fun enableFocusStatusRule(context: Context, nm: NotificationManager) {
        val prefs = context.getSharedPreferences("focus_sync", Context.MODE_PRIVATE)
        var ruleId = prefs.getString(RULE_ID_PREF, null)

        if (ruleId != null) {
            try {
                if (nm.getAutomaticZenRule(ruleId) == null) ruleId = null
            } catch (e: Exception) {
                ruleId = null
            }
        }

        if (ruleId == null) {
            val rule = AutomaticZenRule(
                RULE_NAME,
                null,
                null,
                Uri.parse("condition://com.bluebubbles.messaging/focus_status"),
                null,
                NotificationManager.INTERRUPTION_FILTER_PRIORITY,
                true
            )
            ruleId = nm.addAutomaticZenRule(rule)
            prefs.edit().putString(RULE_ID_PREF, ruleId).apply()
            Log.i("OpenBubbles", "Created Focus Status zen rule: $ruleId")
        } else {
            val rule = nm.getAutomaticZenRule(ruleId)
            if (rule != null && !rule.isEnabled) {
                rule.isEnabled = true
                nm.updateAutomaticZenRule(ruleId, rule)
            }
        }
    }

    private fun disableFocusStatusRule(context: Context, nm: NotificationManager) {
        val prefs = context.getSharedPreferences("focus_sync", Context.MODE_PRIVATE)
        val ruleId = prefs.getString(RULE_ID_PREF, null)
        if (ruleId != null) {
            try {
                val rule = nm.getAutomaticZenRule(ruleId)
                if (rule != null && rule.isEnabled) {
                    rule.isEnabled = false
                    nm.updateAutomaticZenRule(ruleId, rule)
                }
            } catch (e: Exception) {
                Log.w("OpenBubbles", "Failed to disable Focus Status rule: ${e.message}")
            }
        }
        // Also clear the implicit app-managed DND
        nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
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

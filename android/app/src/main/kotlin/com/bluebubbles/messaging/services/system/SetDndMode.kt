package com.bluebubbles.messaging.services.system

import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.ComponentName
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

        if (enabled) {
            enableFocusStatus(context, notificationManager)
        } else {
            disableFocusStatus(context, notificationManager)
        }

        Log.i("OpenBubbles", "Focus sync: set DND mode enabled=$enabled")
        result.success(true)
    }

    private fun enableFocusStatus(context: Context, nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Use an explicit AutomaticZenRule named "Focus Status"
            val prefs = context.getSharedPreferences("focus_sync", Context.MODE_PRIVATE)
            var ruleId = prefs.getString(RULE_ID_PREF, null)

            if (ruleId != null) {
                // Check if the rule still exists
                try {
                    val existing = nm.getAutomaticZenRule(ruleId)
                    if (existing == null) ruleId = null
                } catch (e: Exception) {
                    ruleId = null
                }
            }

            if (ruleId == null) {
                // Create a new rule
                val rule = AutomaticZenRule(
                    RULE_NAME,
                    null, // no owner component
                    null, // no configuration activity
                    Uri.parse("condition://com.bluebubbles.messaging/focus_status"),
                    null, // default zen policy
                    NotificationManager.INTERRUPTION_FILTER_PRIORITY,
                    true
                )
                ruleId = nm.addAutomaticZenRule(rule)
                prefs.edit().putString(RULE_ID_PREF, ruleId).apply()
                Log.i("OpenBubbles", "Created Focus Status zen rule: $ruleId")
            } else {
                // Activate existing rule
                val rule = nm.getAutomaticZenRule(ruleId)
                if (rule != null && !rule.isEnabled) {
                    rule.isEnabled = true
                    nm.updateAutomaticZenRule(ruleId, rule)
                }
            }
        } else {
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
        }
    }

    private fun disableFocusStatus(context: Context, nm: NotificationManager) {
        // First, disable our explicit "Focus Status" rule if it exists
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
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
        }

        // Also try to clear the global DND (user's default mode) if we have permission
        if (hasWriteSecureSettings(context)) {
            try {
                Settings.Global.putInt(context.contentResolver, "zen_mode", 0)
                Log.i("OpenBubbles", "Cleared global DND via WRITE_SECURE_SETTINGS")
            } catch (e: Exception) {
                Log.w("OpenBubbles", "Failed to clear global DND: ${e.message}")
            }
        } else {
            // Fallback: only controls the implicit app-managed DND
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
        }
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

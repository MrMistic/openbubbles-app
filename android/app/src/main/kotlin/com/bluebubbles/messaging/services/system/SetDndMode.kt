package com.bluebubbles.messaging.services.system

import android.app.NotificationManager
import android.content.Context
import android.os.Build
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

        val filter = if (enabled) {
            NotificationManager.INTERRUPTION_FILTER_PRIORITY
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }

        notificationManager.setInterruptionFilter(filter)
        Log.i("OpenBubbles", "Focus sync: set DND mode enabled=$enabled")
        result.success(true)
    }
}

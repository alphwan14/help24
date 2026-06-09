package com.help24.help24

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return

        // Channel id MUST match:
        //   AndroidManifest → com.google.firebase.messaging.default_notification_channel_id
        //   notification_service.dart → _kChannelId
        //   backend notifications.service.ts → android.notification.channelId
        val channel = NotificationChannel(
            "help24_high_importance",
            "Help24 Notifications",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Job updates, payments, and messages"
            enableVibration(true)
            enableLights(true)
            // Explicit sound — without this the channel uses IMPORTANCE_HIGH but
            // Android may still be silent if the system default was not set.
            val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val audioAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            setSound(soundUri, audioAttrs)
        }

        manager.createNotificationChannel(channel)
    }
}

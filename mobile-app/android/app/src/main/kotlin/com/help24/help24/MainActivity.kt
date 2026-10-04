package com.help24.help24

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.help24.help24/documents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> result.success(
                        openDocument(call.argument<String>("path"), call.argument<String>("mimeType")),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Open a cached chat document in the phone's own viewer (chat_documents.dart).
     *
     * Only a file inside files/chat_documents/ and only a document type are
     * accepted; the viewer gets READ access to that single content:// URI,
     * for as long as it shows it. Returns false — never throws — when no
     * installed app can open the type, so Flutter can fall back.
     */
    private fun openDocument(path: String?, mimeType: String?): Boolean {
        if (path == null || mimeType !in DOCUMENT_TYPES) return false
        val root = File(filesDir, "chat_documents").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) || !file.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.documents", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private companion object {
        val DOCUMENT_TYPES = setOf(
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        )
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

package com.help24.help24

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    /** The app link this activity was launched with, handed to Dart once. */
    private var initialLink: String? = null
    private var links: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Only a fresh launch carries a new link; a restore re-delivers the old intent.
        if (savedInstanceState == null) initialLink = appLink(intent)
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        appLink(intent)?.let { links?.invokeMethod("link", it) }
    }

    /**
     * help24.co.ke/a/<CODE> (agent) and /p/<id> (provider card) links only;
     * Dart parses the rest (AgentCodeService, ProviderCardLink).
     */
    private fun appLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        if (intent.action != Intent.ACTION_VIEW || data.scheme != "https") return null
        // Reopened from Recents: Android hands back the intent that first
        // started the task — an old link, already handled. Not a new one.
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
        val path = data.path ?: return null
        if (data.host != "help24.co.ke" || !(path.startsWith("/a/") || path.startsWith("/p/"))) return null
        return data.toString()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.help24.help24/links").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        result.success(initialLink)
                        initialLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.help24.help24/documents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> result.success(
                        openDocument(call.argument<String>("path"), call.argument<String>("mimeType")),
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.help24.help24/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareImage" -> result.success(
                        shareImage(call.argument<String>("path"), call.argument<String>("text")),
                    )
                    else -> result.notImplemented()
                }
            }
        // The in-app updater (app_updater.dart): Dart downloads the APK into
        // cache/updates and checks its SHA-256; this side only answers whether
        // Help24 may install apps, opens that setting, and opens the prompt.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.help24.help24/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canInstallUpdates())
                    "openInstallSettings" -> result.success(openInstallSettings())
                    "install" -> result.success(installUpdate(call.argument<String>("path")))
                    else -> result.notImplemented()
                }
            }
    }

    /** "Install unknown apps" for Help24 (Android 8+; before that, a global setting the prompt itself raises). */
    private fun canInstallUpdates(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Opens Android's install prompt for a downloaded update. Only an .apk
     * inside cache/updates/ is accepted, and the installer gets READ access to
     * that one content:// URI. Android itself refuses an APK not signed with
     * Help24's key, so this cannot install anything else over the app.
     */
    private fun installUpdate(path: String?): Boolean {
        if (path == null || !path.endsWith(".apk")) return false
        val root = File(cacheDir, "updates").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) || !file.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Share a PNG the app rendered (the provider's Help24 card) through the
     * phone's share sheet, with [text] beside it — WhatsApp keeps both.
     *
     * Only a file inside files/shared_cards/ is accepted; the receiving app gets
     * READ access to that one content:// URI. Returns false — never throws —
     * when nothing can receive it, so Flutter can fall back to the link alone.
     */
    private fun shareImage(path: String?, text: String?): Boolean {
        if (path == null || !path.endsWith(".png")) return false
        val root = File(filesDir, "shared_cards").canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith(root.path + File.separator) || !file.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.documents", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            if (text != null) putExtra(Intent.EXTRA_TEXT, text)
            // The chooser only forwards the grant when the URI is also ClipData.
            clipData = ClipData.newRawUri(null, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(Intent.createChooser(send, null))
            true
        } catch (e: ActivityNotFoundException) {
            false
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

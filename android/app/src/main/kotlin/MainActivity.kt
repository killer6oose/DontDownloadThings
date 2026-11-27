// Kept at the top of the kotlin folder rather than in com/killer6oose/snag
// so the project's folders don't get too deep. Kotlin doesn't mind.
package com.killer6oose.snag

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var progressSink: EventChannel.EventSink? = null
    private var firstIntent: String? = null
    private val main = Handler(Looper.getMainLooper())
    private val installAction = "com.killer6oose.snag.INSTALL_STATUS"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ hides the "Downloading" notification unless we ask once.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        firstIntent = textFrom(intent)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Download progress goes to Flutter as a stream of small maps.
        EventChannel(messenger, "snag/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        channel = MethodChannel(messenger, "snag/native").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialIntent" -> {
                        result.success(firstIntent)
                        firstIntent = null
                    }
                    "info" -> result.success(info())

                    // Runs yt-dlp and hands back what it printed. Used for
                    // reading a link's title and for the Spotify searches.
                    "run" -> {
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        background(result) {
                            val response = YoutubeDL.getInstance().execute(YoutubeDLRequest(emptyList()).addCommands(args))
                            response.out
                        }
                    }

                    // Downloads into a private work folder, then moves the
                    // finished files into the phone's Music or Movies folder.
                    "download" -> {
                        val id = call.argument<String>("id")!!
                        val url = call.argument<String>("url")!!
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        val folder = call.argument<String>("folder")!!
                        val work = File(cacheDir, "jobs/$id")
                        DownloadService.started(this@MainActivity)
                        background(result, after = { DownloadService.finished(this@MainActivity) }) {
                            work.deleteRecursively()
                            work.mkdirs()
                            val request = YoutubeDLRequest(url).addCommands(args).addOption("-P", work.absolutePath)
                            YoutubeDL.getInstance().execute(request, id) { progress, eta, line ->
                                main.post {
                                    progressSink?.success(
                                        mapOf("id" to id, "progress" to progress.toDouble(), "eta" to eta, "line" to line)
                                    )
                                }
                            }
                            val saved = saveToPhone(work, folder)
                            work.deleteRecursively()
                            if (saved.isEmpty()) throw Exception("yt-dlp finished but no audio or video file came out")
                            saved
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")!!
                        result.success(YoutubeDL.getInstance().destroyProcessById(id))
                    }
                    "ytDlpVersion" -> background(result) { YoutubeDL.getInstance().version(applicationContext) }
                    "updateYtDlp" -> background(result) {
                        YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel._STABLE)?.name
                    }
                    "open" -> {
                        try {
                            val view = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(Uri.parse(call.argument<String>("uri")), call.argument<String>("mime"))
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(view)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("open", "No app on this phone can open that file", null)
                        }
                    }
                    "openInstallSettings" -> {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("no_file", "No update file given", null)
                        } else {
                            try {
                                install(File(path))
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install", e.message ?: "Couldn't start the install", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    @Volatile
    private var ready = false

    /**
     * Runs [work] off the main thread so the screen doesn't freeze, then
     * replies to Flutter. yt-dlp and ffmpeg get unpacked on first use, which
     * takes a few seconds the very first time the app runs.
     */
    private fun background(result: MethodChannel.Result, after: () -> Unit = {}, work: () -> Any?) {
        Thread {
            try {
                synchronized(this) {
                    if (!ready) {
                        YoutubeDL.getInstance().init(applicationContext)
                        FFmpeg.getInstance().init(applicationContext)
                        ready = true
                    }
                }
                val value = work()
                main.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                main.post { result.error("cancelled", "Cancelled", null) }
            } catch (e: Throwable) {
                // yt-dlp's own error text is the most useful thing to show.
                val message = e.message?.lines()?.lastOrNull { it.contains("ERROR") } ?: e.message ?: e.toString()
                main.post { result.error("failed", message.trim(), null) }
            } finally {
                main.post { after() }
            }
        }.start()
    }

    /**
     * Copies every audio and video file yt-dlp made into the shared folder
     * (e.g. Music/Snag), keeping any playlist subfolder. Anything else left
     * behind (thumbnails, subtitle files) is thrown away with the work folder.
     */
    private fun saveToPhone(work: File, folder: String): List<Map<String, Any>> {
        val saved = mutableListOf<Map<String, Any>>()
        work.walkTopDown().filter { it.isFile }.forEach { file ->
            val ext = file.extension.lowercase()
            val mime = when (ext) {
                "opus", "ogg" -> "audio/ogg"
                "m4a" -> "audio/mp4"
                "flac" -> "audio/flac"
                "mkv" -> "video/x-matroska"
                "webm" -> "video/webm"
                else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: ""
            }
            if (!mime.startsWith("audio/") && !mime.startsWith("video/")) return@forEach

            val sub = file.parentFile!!.relativeTo(work).path
            val relative = if (sub.isEmpty()) folder else "$folder/$sub"
            val collection = when {
                relative.startsWith("Download") -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                mime.startsWith("audio/") -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                else -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$relative/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values)
                ?: throw Exception("Android wouldn't let Snag save into $relative")
            contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            saved.add(mapOf("name" to file.name, "uri" to uri.toString(), "mime" to mime, "size" to file.length(), "folder" to relative))
        }
        return saved
    }

    // Opened again while already running, e.g. sharing a second video.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        textFrom(intent)?.let { channel?.invokeMethod("incoming", it) }
    }

    /** The text another app shared to Snag, usually a title and a link. */
    private fun textFrom(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }
    }

    private fun info(): Map<String, Any?> {
        val p = packageManager.getPackageInfo(packageName, 0)
        return mapOf(
            "versionName" to p.versionName,
            "versionCode" to p.longVersionCode,
            "cacheDir" to cacheDir.absolutePath,
            "canInstall" to packageManager.canRequestPackageInstalls(),
        )
    }

    /** Hands a downloaded Snag update to Android's installer. */
    private fun install(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("update.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            listenForStatus()
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val status = PendingIntent.getBroadcast(this, sessionId, Intent(installAction).setPackage(packageName), flags)
            session.commit(status.intentSender)
        }
    }

    private var statusReceiver: BroadcastReceiver? = null

    private fun listenForStatus() {
        if (statusReceiver != null) return
        statusReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        if (confirm != null) startActivity(confirm)
                    }
                    PackageInstaller.STATUS_SUCCESS -> {}
                    else -> {
                        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Android didn't say why"
                        channel?.invokeMethod("installFailed", message)
                    }
                }
            }
        }
        val filter = IntentFilter(installAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, filter)
        }
    }

    override fun onDestroy() {
        statusReceiver?.let { unregisterReceiver(it) }
        statusReceiver = null
        super.onDestroy()
    }
}

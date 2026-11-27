package com.killer6oose.snag

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * Keeps Snag alive while something is downloading, so switching back to
 * YouTube after sharing a link doesn't get the download killed. It only
 * shows the "Downloading" notification; the actual work happens in
 * MainActivity's background threads.
 */
class DownloadService : Service() {
    companion object {
        private var running = 0

        fun started(context: Context) {
            running++
            context.startForegroundService(Intent(context, DownloadService::class.java))
        }

        fun finished(context: Context) {
            running = maxOf(0, running - 1)
            if (running == 0) {
                context.stopService(Intent(context, DownloadService::class.java))
            } else {
                context.startForegroundService(Intent(context, DownloadService::class.java))
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel("downloads", "Downloads", NotificationManager.IMPORTANCE_LOW)
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, "downloads")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Snag")
            .setContentText(if (running == 1) "Downloading 1 item" else "Downloading $running items")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        return START_NOT_STICKY
    }
}

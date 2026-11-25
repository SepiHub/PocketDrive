package com.sepihub.pocketdrive_phone

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocketdrive/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Whether Android lets this app open the "install update" screen.
                    "canInstall" -> result.success(canInstall())
                    // Opens Settings so the user can allow it (once).
                    "allowInstalls" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    // Hands a downloaded APK to Android's installer, which
                    // asks the user to confirm. Only files in our update
                    // cache folder are accepted.
                    "install" -> {
                        val path = call.argument<String>("path")
                        val dir = File(cacheDir, "updates").canonicalFile
                        val file = path?.let { File(it).canonicalFile }
                        if (file == null || file.parentFile != dir || !file.isFile) {
                            result.error("bad_path", "Not an update file", null)
                        } else {
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.updates", file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
}

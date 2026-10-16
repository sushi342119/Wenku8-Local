package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Installs only newer, same-package APKs signed by the app's signing lineage. */
class AppUpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        attached = true
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/app_updates")
        channel.setMethodCallHandler(this)
    }
    @Suppress("DEPRECATION")
    private fun info(): PackageInfo = context.packageManager.getPackageInfo(context.packageName,
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> try {
                val current = info()
                result.success(mapOf("version" to current.versionName, "build" to code(current), "abis" to Build.SUPPORTED_ABIS.toList()))
            } catch (_: Exception) { result.error("VERSION", "无法读取当前应用版本", null) }
            "allowInstalls" -> withActivity(result) { page ->
                if (Build.VERSION.SDK_INT >= 26) page.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")))
                result.success(null)
            }
            "openRelease" -> withActivity(result) { page ->
                val uri = Uri.parse(call.arguments as? String ?: "")
                require(uri.scheme == "https" && uri.host == "github.com" && uri.userInfo == null && uri.path.orEmpty().contains("/releases/"))
                page.startActivity(Intent(Intent.ACTION_VIEW, uri))
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path") ?: ""
                val version = call.argument<String>("version") ?: ""
                io.execute {
                    try {
                        val apk = validateApk(path, version)
                        main.post {
                            if (!attached) return@post
                            withActivity(result) { page ->
                                if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
                                    result.success("permission")
                                } else {
                                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", apk)
                                    page.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, "application/vnd.android.package-archive")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    })
                                    result.success("opened")
                                }
                            }
                        }
                    } catch (failure: Exception) {
                        main.post { if (attached) result.error("APK_REJECTED", failure.message ?: "安装包无法验证，请重新下载", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(path: String, version: String): File {
        val root = File(context.cacheDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == root && apk.name == "update.apk" && apk.isFile) { "安装包路径无效，请重新下载" }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = context.packageManager.getPackageArchiveInfo(apk.path, flags)
            ?: throw IllegalArgumentException("安装包不完整，请重新下载")
        val current = info()
        require(archive.packageName == context.packageName) { "安装包不属于本应用" }
        require(archive.versionName == version && code(archive) > code(current)) { "安装包版本不匹配或不是较新版本" }
        val signed = if (Build.VERSION.SDK_INT >= 28) {
            val old = current.signingInfo ?: throw IllegalArgumentException("无法读取当前签名")
            val next = archive.signingInfo ?: throw IllegalArgumentException("安装包缺少有效签名")
            if (old.hasMultipleSigners() || next.hasMultipleSigners()) {
                old.apkContentsSigners.toSet() == next.apkContentsSigners.toSet()
            } else {
                next.signingCertificateHistory.orEmpty().contains(old.apkContentsSigners.singleOrNull())
            }
        } else current.signatures.orEmpty().toSet() == archive.signatures.orEmpty().toSet() && !archive.signatures.isNullOrEmpty()
        require(signed) { "安装包签名与当前版本不一致，无法覆盖升级" }
        return apk
    }

    private fun withActivity(result: MethodChannel.Result, action: (Activity) -> Unit) {
        val page = activity
        if (page == null || page.isFinishing) result.error("NO_ACTIVITY", "请在应用内重试", null)
        else try { action(page) } catch (_: Exception) { result.error("OPEN", "系统页面无法打开，请重试", null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        io.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
}

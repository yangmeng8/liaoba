package com.example.liaoba

import android.media.MediaPlayer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

// 极光推送通知点击桥接（迁移自 app_im 的 MainActivity）：
// - 点击通知拉起 App（含冷启动 pending 点击缓存与消费）
// - bringAppToFront 把后台 App 切回前台
// - 解析 JPush Intent extras 构造 Flutter 可读的 payload
// - 来电 fullScreenIntent 全屏通知（锁屏直接全屏弹来电界面，
//   复用 push_open 冷启动消费链路：n_extras → Dart 识别 call_invite → 来电页）
class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val PUSH_OPEN_CHANNEL = "im/push_open"
        private const val METHOD_ON_NOTIFICATION_OPENED = "onNotificationOpened"
        private const val METHOD_CONSUME_PENDING_OPEN = "consumePendingNotificationOpen"
        private const val METHOD_BRING_APP_TO_FRONT = "bringAppToFront"

        private const val INCOMING_CALL_CHANNEL = "im/incoming_call"
        private const val CALL_CHANNEL_ID = "im_incoming_call"
        private const val CALL_NOTIFICATION_ID = 2001
    }

    private var pushOpenChannel: MethodChannel? = null
    private var pendingNotificationOpen: HashMap<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cachePushOpenPayload("onCreate", intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        cachePushOpenPayload("onNewIntent", intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pushOpenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PUSH_OPEN_CHANNEL,
        ).apply {
            setMethodCallHandler(::handlePushOpenChannelCall)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INCOMING_CALL_CHANNEL,
        ).setMethodCallHandler(::handleIncomingCallChannelCall)
        dispatchPendingNotificationOpen("configureFlutterEngine")
    }

    private fun handleIncomingCallChannelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showIncomingCall" -> {
                showIncomingCallNotification(
                    call.argument<String>("title"),
                    call.argument<String>("content"),
                    call.argument<String>("extrasJson"),
                )
                result.success(true)
            }

            "cancelIncomingCall" -> {
                try {
                    NotificationManagerCompat.from(this).cancel(CALL_NOTIFICATION_ID)
                } catch (t: Throwable) {
                    Log.w(TAG, "cancelIncomingCall: failed", t)
                }
                result.success(true)
            }

            "startRingback" -> {
                startRingback()
                result.success(true)
            }

            "stopRingback" -> {
                stopRingback()
                result.success(true)
            }

            "startRingtone" -> {
                startRingtone()
                result.success(true)
            }

            "stopRingtone" -> {
                stopRingtone()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    /// 回铃音 MediaPlayer（主叫等待接听：1 秒嘟 + 3 秒静音循环）
    private var ringbackPlayer: MediaPlayer? = null

    private fun startRingback() {
        if (ringbackPlayer?.isPlaying == true) return
        try {
            val player = MediaPlayer.create(this, R.raw.ringback)
            player.isLooping = true
            player.start()
            ringbackPlayer = player
            Log.d(TAG, "startRingback: ok")
        } catch (t: Throwable) {
            Log.w(TAG, "startRingback: failed", t)
        }
    }

    private fun stopRingback() {
        try {
            ringbackPlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stopRingback: failed", t)
        }
        ringbackPlayer = null
    }

    /// 被叫振铃音（来电页弹出时循环，复用来电铃声 push_notification_v3）
    private var ringtonePlayer: MediaPlayer? = null

    private fun startRingtone() {
        if (ringtonePlayer?.isPlaying == true) return
        try {
            val player = MediaPlayer.create(this, R.raw.push_notification_v3)
            player.isLooping = true
            player.start()
            ringtonePlayer = player
            Log.d(TAG, "startRingtone: ok")
        } catch (t: Throwable) {
            Log.w(TAG, "startRingtone: failed", t)
        }
    }

    private fun stopRingtone() {
        try {
            ringtonePlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stopRingtone: failed", t)
        }
        ringtonePlayer = null
    }

    /// 来电 fullScreenIntent 全屏通知：
    /// - 锁屏/熄屏：系统直接点亮屏幕并全屏启动 MainActivity（微信式来电界面）
    /// - 亮屏后台：显示 heads-up 横幅，点击全屏进入
    /// - 通知渠道绑定 30s 嘟嘟声铃声（res/raw/push_notification_v3）
    /// - fullScreenPendingIntent 复用 push_open 冷启动消费链路
    ///   （n_extras JSON → buildPushOpenPayload → Dart 识别 call_invite → 弹来电页）
    private fun showIncomingCallNotification(title: String?, content: String?, extrasJson: String?) {
        try {
            val soundUri = Uri.parse("android.resource://$packageName/raw/push_notification_v3")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CALL_CHANNEL_ID,
                    "来电提醒",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "音视频来电全屏提醒"
                    setSound(
                        soundUri,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    enableLights(true)
                    lightColor = Color.RED
                }
                getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            }

            val fullScreenIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
                putExtra("n_title", title ?: "IM")
                putExtra("n_content", content ?: "来电邀请")
                putExtra("n_extras", extrasJson ?: "{}")
                putExtra("from_full_screen_call", true)
            }
            if (fullScreenIntent == null) {
                Log.w(TAG, "showIncomingCallNotification: launchIntent is null")
                return
            }
            val fullScreenPendingIntent = PendingIntent.getActivity(
                this,
                CALL_NOTIFICATION_ID + 1,
                fullScreenIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val builder =
                NotificationCompat.Builder(this, CALL_CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.ic_menu_call)
                    .setContentTitle(title ?: "IM")
                    .setContentText(content ?: "来电邀请")
                    .setCategory(NotificationCompat.CATEGORY_CALL)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setFullScreenIntent(fullScreenPendingIntent, true)
                    .setOngoing(true)
                    .setAutoCancel(true)
            NotificationManagerCompat.from(this).notify(CALL_NOTIFICATION_ID, builder.build())
            Log.i(TAG, "showIncomingCallNotification: posted (title=$title)")
        } catch (t: Throwable) {
            Log.w(TAG, "showIncomingCallNotification: failed", t)
        }
    }

    private fun handlePushOpenChannelCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_CONSUME_PENDING_OPEN -> {
                result.success(pendingNotificationOpen)
                pendingNotificationOpen = null
            }

            METHOD_BRING_APP_TO_FRONT -> {
                bringAppToFront()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun bringAppToFront() {
        try {
            val launchIntent =
                packageManager.getLaunchIntentForPackage(packageName)?.apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                    )
                    pendingNotificationOpen?.let { payload ->
                        val extras = payload["extras"]
                        if (extras is Map<*, *>) {
                            for ((key, value) in extras) {
                                if (key != null && value is String) {
                                    putExtra(key.toString(), value)
                                }
                            }
                        }
                    }
                }

            if (launchIntent == null) {
                Log.w(TAG, "bringAppToFront: launchIntent is null")
                return
            }
            startActivity(launchIntent)
            Log.i(TAG, "bringAppToFront: started MainActivity")
        } catch (t: Throwable) {
            Log.w(TAG, "bringAppToFront: failed", t)
        }
    }

    private fun cachePushOpenPayload(stage: String, intent: Intent?) {
        val payload = buildPushOpenPayload(intent) ?: return
        pendingNotificationOpen = payload
        Log.i(TAG, "[$stage] cached push-open payload: $payload")
        dispatchPendingNotificationOpen(stage)
    }

    private fun dispatchPendingNotificationOpen(stage: String) {
        val payload = pendingNotificationOpen ?: return
        val channel = pushOpenChannel ?: return
        try {
            channel.invokeMethod(METHOD_ON_NOTIFICATION_OPENED, payload)
            Log.i(TAG, "[$stage] dispatched push-open payload to Flutter")
        } catch (t: Throwable) {
            Log.w(TAG, "[$stage] failed to dispatch push-open payload", t)
        }
    }

    // 从启动 Intent 解析极光通知点击 payload（兼容通知/自定义消息两套 extras 键）。
    private fun buildPushOpenPayload(intent: Intent?): HashMap<String, Any?>? {
        val bundle = intent?.extras ?: return null
        if (bundle.isEmpty) {
            return null
        }
        val bundleMap = bundleToMap(bundle)
        val jpushExtra = parseMaybeJsonMap(
            bundleMap["cn.jpush.android.EXTRA"] ?: bundleMap["n_extras"],
        )
        val title =
            bundleMap["cn.jpush.android.NOTIFICATION_CONTENT_TITLE"]
                ?: bundleMap["cn.jpush.android.NOTIFICATION_TITLE"]
                ?: bundleMap["n_title"]
        val alert =
            bundleMap["cn.jpush.android.ALERT"]
                ?: bundleMap["cn.jpush.android.NOTIFICATION_CONTENT"]
                ?: bundleMap["n_content"]
        val msgId =
            bundleMap["cn.jpush.android.MSG_ID"]
                ?: bundleMap["msg_id"]
                ?: bundleMap["_j_msgid"]

        val extras = hashMapOf<String, Any?>().apply {
            putAll(bundleMap)
            if (jpushExtra.isNotEmpty()) {
                put("cn.jpush.android.EXTRA", jpushExtra)
            }
            if (msgId != null) {
                put("cn.jpush.android.MSG_ID", msgId)
            }
        }

        if (title == null && alert == null && jpushExtra.isEmpty() && msgId == null) {
            return null
        }

        return hashMapOf(
            "title" to title,
            "alert" to alert,
            "extras" to extras,
        )
    }

    private fun bundleToMap(bundle: Bundle): HashMap<String, Any?> {
        val map = hashMapOf<String, Any?>()
        for (key in bundle.keySet()) {
            map[key] = normalizeValue(bundle.get(key))
        }
        return map
    }

    private fun normalizeValue(value: Any?): Any? {
        return when (value) {
            is Bundle -> bundleToMap(value)
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            is String -> parseMaybeJson(value)
            is ArrayList<*> -> ArrayList(value.map { normalizeValue(it) })
            else -> value
        }
    }

    private fun parseMaybeJson(value: String): Any {
        val trimmed = value.trim()
        if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
            return try {
                jsonObjectToMap(JSONObject(trimmed))
            } catch (_: Throwable) {
                value
            }
        }
        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            return try {
                jsonArrayToList(JSONArray(trimmed))
            } catch (_: Throwable) {
                value
            }
        }
        return value
    }

    private fun parseMaybeJsonMap(value: Any?): HashMap<String, Any?> {
        return when (val normalized = normalizeValue(value)) {
            is HashMap<*, *> -> HashMap(
                normalized.entries.associate { entry ->
                    entry.key.toString() to entry.value
                },
            )

            is Map<*, *> -> HashMap(
                normalized.entries.associate { entry ->
                    entry.key.toString() to entry.value
                },
            )

            else -> hashMapOf()
        }
    }

    private fun jsonObjectToMap(jsonObject: JSONObject): HashMap<String, Any?> {
        val map = hashMapOf<String, Any?>()
        val iterator = jsonObject.keys()
        while (iterator.hasNext()) {
            val key = iterator.next()
            map[key] = normalizeValue(jsonObject.opt(key))
        }
        return map
    }

    private fun jsonArrayToList(jsonArray: JSONArray): ArrayList<Any?> {
        val list = arrayListOf<Any?>()
        for (index in 0 until jsonArray.length()) {
            list.add(normalizeValue(jsonArray.opt(index)))
        }
        return list
    }
}

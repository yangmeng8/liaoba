package com.example.liaoba

import android.content.Intent
import android.os.Bundle
import android.util.Log
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
class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val PUSH_OPEN_CHANNEL = "im/push_open"
        private const val METHOD_ON_NOTIFICATION_OPENED = "onNotificationOpened"
        private const val METHOD_CONSUME_PENDING_OPEN = "consumePendingNotificationOpen"
        private const val METHOD_BRING_APP_TO_FRONT = "bringAppToFront"
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
        dispatchPendingNotificationOpen("configureFlutterEngine")
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

package com.tvrain.barometer_flutter

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Synthetic tasks and trusted local documents shared by the instrumented tests. */
internal object DeviceTestDocuments {
    const val ISSUER = "embedded-issuer"

    private fun utc(millis: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
            .format(Date(millis))

    /** A one-time embedded task; [networkPath] selects the proxy path when it is "proxy". */
    fun runTask(id: String, test: String, input: JSONObject, networkPath: String? = null): String {
        val execution = JSONObject().put("limits", JSONObject())
        if (networkPath != null) execution.put("network_path", networkPath)
        return JSONObject()
            .put("schema_version", "0.1.0").put("task_id", id).put("test_id", test)
            .put("test_version", "0.1.0").put("input", input).put("options", JSONObject())
            .put("schedule", JSONObject().put("not_after", utc(System.currentTimeMillis() + 86_400_000L)))
            .put("execution", execution)
            .put("safety", JSONObject().put("risk_level", "low").put("requires_user_consent", false))
            .toString()
    }

    /**
     * A synthetic `barometer-trust/1` document permitting [test] against one registered
     * target for the deployment and the embedded issuer, with [connectionCodes] approved for a
     * host-configured proxy. It is built when the test runs because the registration expires
     * 48 hours later.
     */
    fun trustDocument(test: String, tuple: JSONObject, connectionCodes: List<String> = emptyList()): ByteArray {
        val testRef = JSONObject().put("id", test).put("version", "0.1.0")
        val paths = JSONObject().put("direct", true).put("proxy", true)
        val registration = JSONObject()
            .put("id", "reg-a").put("test", testRef).put("role", "measurement").put("tuple", tuple)
            .put("paths", paths).put("baseline_risk", "low").put("owner", "synthetic")
            .put("purpose", "synthetic").put("review_generation", 1)
            .put("expires_at", utc(System.currentTimeMillis() + 48 * 3_600_000L))
            .put("redirect_ids", JSONArray())
        val limits = JSONObject()
            .put("attempt", JSONObject().put("duration_ms", 60000).put("bytes_sent", 65536)
                .put("bytes_received", 262144).put("connections", 12))
            .put("max_runs", 28).put("max_attempts", 2).put("max_validity_seconds", 604800)
            .put("min_repeat_interval_seconds", 21600).put("min_repeat_jitter_seconds", 300)
            .put("min_retry_delay_ms", 30000).put("max_retry_delay_ms", 600000)
            .put("max_retry_jitter_ms", 60000).put("max_result_bytes", 65536)
            .put("max_bundle_bytes", 262144).put("max_results_per_bundle", 16)
            .put("max_pending_bundles", 32).put("max_pending_bytes", 4194304)
            .put("max_retention_seconds", 86400)
        fun permissions() = JSONObject()
            .put("tests", JSONArray().put(testRef)).put("registration_ids", JSONArray().put("reg-a"))
            .put("paths", paths).put("max_risk", "high").put("require_consent", false)
            .put("allow_medium_risk", true).put("allow_composite", false)
            .put("allow_unknown_risk", true).put("label_namespaces", JSONArray())
            .put("limits", limits)
        val policy = JSONObject()
            .put("generation", 2).put("permissions", permissions())
            .put("issuers", JSONArray().put(JSONObject().put("issuer_id", ISSUER).put("permissions", permissions())))
            .put("targets", JSONArray().put(registration)).put("keys", JSONArray())
        return JSONObject()
            .put("format", "barometer-trust/1").put("policy", policy)
            .put("configuration_approvals", JSONObject().put("endpoints", JSONArray())
                .put("connection_codes", JSONArray(connectionCodes)).put("linkage_scopes", JSONArray())
                .put("allow_linkage", false))
            .put("context_approvals", JSONObject().put("connection_codes", JSONArray())
                .put("classification_versions", JSONArray()).put("country_codes", JSONArray())
                .put("region_codes", JSONArray()))
            .toString().toByteArray()
    }
}

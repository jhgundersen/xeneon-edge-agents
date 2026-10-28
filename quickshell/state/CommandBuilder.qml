import QtQml

QtObject {
    id: root

    readonly property var allowedActions: [
        "open",
        "zoom",
        "approve",
        "interrupt",
        "restore_focus",
        "desktop_app",
        "voice_start",
        "voice_stop",
        "voice_cancel",
        "order_grouped",
        "order_priority",
        "backend_herdr",
        "backend_t3code"
    ]

    property int requestCounter: 0
    property string lastError: ""

    function reset() {
        requestCounter = 0
        lastError = ""
    }

    function build(action, agentId, capabilityId, pinnedSequence, appId) {
        lastError = ""

        if (allowedActions.indexOf(action) === -1) {
            lastError = "Action is not allowlisted"
            return null
        }

        var normalizedAgentId = String(agentId || "")
        var normalizedCapabilityId = String(capabilityId || "")
        var normalizedAppId = String(appId || "")
        var normalizedSequence = Number(pinnedSequence)

        if (!isFinite(normalizedSequence) || normalizedSequence < 0) {
            lastError = "Command requires a valid snapshot sequence"
            return null
        }

        var systemAction = action === "restore_focus"
            || action === "desktop_app"
            || action === "voice_start"
            || action === "voice_stop"
            || action === "voice_cancel"
            || action === "order_grouped"
            || action === "order_priority"
            || action === "backend_herdr"
            || action === "backend_t3code"

        if (systemAction) {
            if (normalizedAgentId !== ""
                    || normalizedCapabilityId !== "") {
                lastError = "System action cannot target an agent or capability"
                return null
            }
        } else if (normalizedAgentId === "") {
            lastError = "Agent action requires an agent_id"
            return null
        }

        if ((action === "approve" || action === "interrupt")
                && normalizedCapabilityId === "") {
            lastError = "Guarded action requires a capability_id"
            return null
        }

        if ((action === "open" || action === "zoom" || systemAction)
                && normalizedCapabilityId !== "") {
            lastError = "Direct action cannot include a capability_id"
            return null
        }

        if (action === "desktop_app"
                && !/^[a-z0-9-]{1,32}$/.test(normalizedAppId)) {
            lastError = "Desktop app action requires a configured app_id"
            return null
        }

        if (action !== "desktop_app" && normalizedAppId !== "") {
            lastError = "Only desktop_app accepts an app_id"
            return null
        }

        requestCounter += 1
        var command = {
            "schema_version": 1,
            "type": "command",
            "request_id": "xep-" + Date.now() + "-" + requestCounter,
            "sequence": Math.floor(normalizedSequence),
            "action": action
        }

        if (normalizedAgentId !== "")
            command.agent_id = normalizedAgentId

        if (normalizedCapabilityId !== "")
            command.capability_id = normalizedCapabilityId

        if (normalizedAppId !== "")
            command.app_id = normalizedAppId

        return command
    }
}

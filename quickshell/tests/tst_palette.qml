import QtQuick
import QtTest
import "../components"
import "../components/PortalPalette.js" as Palette

TestCase {
    name: "PortalPalette"

    property var semanticTheme: ({
        "blue": "#123456",
        "yellow": "#654321",
        "green": "#246813",
        "red": "#975310",
        "magenta": "#864209",
        "cyan": "#135724",
        "muted": "#555555",
        "working": "#112233",
        "needsHelp": "#332211",
        "reviewReady": "#224422",
        "error": "#442222",
        "unknown": "#442244",
        "ready": "#444444",
        "success": "#225522",
        "recording": "#225533",
        "processing": "#224455",
        "border": "#333333",
        "surface": "#111111",
        "textPrimary": "#eeeeee"
    })

    function agent(status, reviewReady) {
        return {
            "status": status,
            "review_ready": reviewReady === true
        }
    }

    function test_agentColorsFollowThemeSemanticRoles() {
        compare(
            String(Palette.agentColor(agent("working"), semanticTheme)),
            semanticTheme.working
        )
        compare(
            String(Palette.agentColor(agent("blocked"), semanticTheme)),
            semanticTheme.needsHelp
        )
        compare(
            String(Palette.agentColor(agent("done", true), semanticTheme)),
            semanticTheme.reviewReady
        )
        compare(
            String(Palette.agentColor(agent("done", false), semanticTheme)),
            semanticTheme.ready
        )
        compare(
            String(Palette.agentColor(agent("unknown"), semanticTheme)),
            semanticTheme.unknown
        )
    }

    function test_ambientColorsFollowThemeSemanticRoles() {
        compare(
            Palette.ambientColor("working", semanticTheme),
            semanticTheme.working
        )
        compare(
            Palette.ambientColor("blocked", semanticTheme),
            semanticTheme.needsHelp
        )
        compare(
            Palette.ambientColor("review", semanticTheme),
            semanticTheme.reviewReady
        )
        compare(
            Palette.ambientColor("error", semanticTheme),
            semanticTheme.error
        )
        compare(
            Palette.ambientColor("voice-processing", semanticTheme),
            semanticTheme.processing
        )
        compare(
            Palette.ambientColor("voice-recording", semanticTheme),
            semanticTheme.recording
        )
        compare(
            Palette.ambientColor("off", semanticTheme),
            semanticTheme.ready
        )
    }

    function test_reviewReadyOverridesIdleButNotActiveAttention() {
        compare(Palette.effectiveAgentState(agent("idle", true)), "review")
        compare(Palette.effectiveAgentState(agent("working", true)), "working")
        compare(Palette.effectiveAgentState(agent("blocked", true)), "blocked")
        compare(Palette.effectiveAgentState(agent("done", false)), "idle")
    }

    function test_voiceOverridesAggregateRing() {
        var agents = [agent("blocked"), agent("working")]
        compare(Palette.ambientMode(
            agents,
            {"state": "recording"},
            "connected"
        ), "voice-recording")
        compare(Palette.ambientMode(
            agents,
            {"state": "processing"},
            "connected"
        ), "voice-processing")
        compare(Palette.ambientMode(
            agents,
            {"state": "error"},
            "connected"
        ), "voice-error")
    }

    function test_aggregateRingUsesMicroAttentionPriority() {
        compare(Palette.ambientMode(
            [agent("working"), agent("idle")],
            {"state": "idle"},
            "connected"
        ), "working")
        compare(Palette.ambientMode(
            [agent("working"), agent("idle", true)],
            {"state": "idle"},
            "connected"
        ), "review")
        compare(Palette.ambientMode(
            [agent("blocked"), agent("idle", true)],
            {"state": "idle"},
            "connected"
        ), "blocked")
    }

}

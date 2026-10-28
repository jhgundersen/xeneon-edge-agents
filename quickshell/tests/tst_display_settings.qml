import QtQuick
import QtTest
import "../components"

TestCase {
    id: testCase

    name: "DisplaySettings"
    width: 240
    height: 80

    DisplaySettingsControls {
        id: settings
    }

    SignalSpy {
        id: dimSpy
        target: settings
        signalName: "dimToggleRequested"
    }

    SignalSpy {
        id: paletteSpy
        target: settings
        signalName: "paletteToggleRequested"
    }

    function init() {
        settings.dimmed = false
        settings.paletteOpen = false
        settings.paletteCustom = false
        dimSpy.clear()
        paletteSpy.clear()
    }

    function test_buttonsExposeCurrentGlobalState() {
        var dim = findChild(settings, "dimSettingButton")
        var palette = findChild(settings, "paletteSettingButton")

        verify(dim !== null)
        verify(palette !== null)
        // Motion is no longer a header control.
        compare(findChild(settings, "motionSettingButton"), null)
        compare(dim.checked, false)
        compare(dim.stateLabel, "NORMAL")
        compare(palette.checked, false)
        compare(palette.stateLabel, "THEME")

        settings.dimmed = true
        compare(dim.checked, true)
        compare(dim.stateLabel, "MINIMUM")
        settings.paletteCustom = true
        compare(palette.checked, true)
        compare(palette.stateLabel, "CUSTOM")
        settings.paletteOpen = true
        compare(palette.stateLabel, "OPEN")
    }

    function test_activationRequestsExactlyOneToggle() {
        var dim = findChild(settings, "dimSettingButton")
        var palette = findChild(settings, "paletteSettingButton")

        compare(dim.activate(), true)
        compare(dimSpy.count, 1)
        compare(paletteSpy.count, 0)

        compare(palette.activate(), true)
        compare(dimSpy.count, 1)
        compare(paletteSpy.count, 1)
    }
}

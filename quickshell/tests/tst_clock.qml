import QtQuick
import QtTest
import "../components"
import "../state/ThemePalette.js" as ThemePalette

TestCase {
    id: testCase

    name: "Clock"
    width: 400
    height: 80

    ClockCard {
        id: clock

        width: 340
        height: 58
        theme: ThemePalette.fallback
        reducedMotion: true
    }

    function test_showsTheCurrentTimeAndDate() {
        compare(clock.time, Qt.formatTime(new Date(), "HH:mm"))
        compare(
            findChild(clock, "clockWeekday").text,
            Qt.formatDate(new Date(), "dddd").toUpperCase()
        )
        verify(findChild(clock, "clockTime") !== null)
    }

    function test_minuteSweepTracksTheSeconds() {
        clock.syncMinute()
        var expected = (new Date().getSeconds() * 1000 + new Date().getMilliseconds()) / 60000
        verify(clock.minuteProgress >= 0 && clock.minuteProgress <= 1)
        verify(Math.abs(clock.minuteProgress - expected) < 0.05)
    }

    function test_motionAnimatesTheSweepAndReducedMotionHoldsIt() {
        clock.reducedMotion = false
        var start = clock.minuteProgress
        wait(400)
        // Within one minute the sweep only moves forward (or restarts at 0).
        verify(clock.minuteProgress > start || clock.minuteProgress < 0.02)
        clock.reducedMotion = true
        var held = clock.minuteProgress
        wait(300)
        compare(clock.minuteProgress, held)
    }
}

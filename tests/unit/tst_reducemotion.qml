import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml" as PreviewQml

// Reduce Motion replaces motion instead of shortening it (ADR-0039 step 5, G10; macOS: slides become fades): a switch's knob
// jumps to its side, Settings' spinner and Preview's animated images stand still. Without the setting the knob slides and the
// spinner steps. The shell's surfaces (banners, the Notification Center, the Overview tiles, Search, the stack fan, the OSD,
// the saver) need Quickshell: tests/shell/reduce_motion_wiring.sh holds their gating, the nested pass their look.
TestCase {
    id: tc

    name: "ReduceMotion"
    width: 300
    height: 200
    visible: true
    when: windowShown

    Column {
        Toggle { id: toggle; checked: false }
        Switch { id: switchControl; checked: false }
        Spinner { id: spinner }
        PreviewQml.ImageView {
            id: imageView
            width: 200
            height: 100
            info: ({animated: true, width: 10, height: 10, url: ""})
        }
    }

    property bool wasReduced: false

    function initTestCase() {
        tc.wasReduced = Appearance.reduceMotion;
    }

    function cleanup() {
        Appearance.reduceMotion = tc.wasReduced;
        toggle.checked = false;
        switchControl.checked = false;
        wait(Tokens.motionSlow);
    }

    // The knob: the rectangle of the knob's size in the control.
    function knobOf(control) {
        const stack = [control];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it !== control && String(it).indexOf("QQuickRectangle") === 0 && it.visible
                    && Math.abs(it.width - Tokens.controlToggleKnobWidth) < 0.01 && Math.abs(it.height - Tokens.controlToggleKnobHeight) < 0.01)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_knobs_data() {
        return [{tag: "toggle", control: toggle}, {tag: "switch", control: switchControl}];
    }

    function test_knobs(data) {
        const knob = knobOf(data.control);
        verify(knob !== null, "the " + data.tag + "'s knob");
        const off = knob.x;
        // Without the setting the knob slides: right after the change it is still on its way.
        Appearance.reduceMotion = false;
        data.control.checked = true;
        const sliding = knob.x;
        tryVerify(() => knob.x > sliding, Tokens.motionSlow * 4, "the knob slides");
        wait(Tokens.motionSlow * 2);
        const on = knob.x;
        verify(sliding < on, "it started from short of its side: " + sliding + " < " + on);
        verify(on > off);
        data.control.checked = false;
        tryCompare(knob, "x", off, Tokens.motionSlow * 4);
        // Under Reduce Motion it is at its side at once, with no frame in between.
        Appearance.reduceMotion = true;
        data.control.checked = true;
        compare(knob.x, on, "the knob jumps under Reduce Motion");
        data.control.checked = false;
        compare(knob.x, off);
    }

    function test_spinnerStandsStill() {
        Appearance.reduceMotion = false;
        const first = spinner.step;
        tryVerify(() => spinner.step !== first, Tokens.controlSpinnerStepMs * 4, "the spinner steps");
        Appearance.reduceMotion = true;
        const still = spinner.step;
        wait(Tokens.controlSpinnerStepMs * 3);
        compare(spinner.step, still, "the spinner stands still under Reduce Motion");
    }

    // The AnimatedImage of the view (the animated kind).
    function animatedImageOf(item) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickAnimatedImage") === 0)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_animatedImagesWaitWithAPlayControl() {
        const image = animatedImageOf(imageView);
        verify(image !== null);
        verify(image.visible, "an animated file shows its AnimatedImage");
        const control = findChild(imageView, "animatedPlayControl");
        verify(control !== null);
        Appearance.reduceMotion = false;
        verify(image.playing);
        verify(!control.visible, "no control while the image plays on its own");
        // Under Reduce Motion it waits on its first frame with a play control (macOS: "Auto-play animated images" off).
        Appearance.reduceMotion = true;
        verify(!image.playing, "an animated image waits under Reduce Motion");
        compare(image.currentFrame, 0);
        verify(control.visible);
        imageView.playRequested = true;
        verify(image.playing, "the viewer plays it");
        imageView.playRequested = false;
        verify(!image.playing);
        // The viewer's play ends with the setting's change and with another file.
        imageView.playRequested = true;
        Appearance.reduceMotion = false;
        Appearance.reduceMotion = true;
        verify(!imageView.playRequested && !image.playing);
        imageView.playRequested = true;
        imageView.info = ({animated: true, width: 12, height: 12, url: ""});
        verify(!imageView.playRequested, "another file starts waiting");
    }
}

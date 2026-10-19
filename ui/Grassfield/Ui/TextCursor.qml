import QtQuick

// Text (I-beam) pointer over a text input. Put it inside the TextInput or TextEdit, or inside the box around a field:
//
//     TextInput { ...  TextCursor {} }
//
// A HoverHandler requests the cursor shape through the window (Qt sends wp_cursor_shape_v1 on Wayland when the
// compositor offers it, an XCursor "text" image otherwise). It passes every event through: clicks, selection and
// focus stay with the field. A MouseArea that sits under the field and swallows clicks does not hide it: the
// handler works on the item under the pointer, not on the first MouseArea.
HoverHandler {
    cursorShape: Qt.IBeamCursor
}

pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The scope bar of a search location (ADR-0027, macOS 27 Finder-Search): "Search:", This Computer and the folder the
// search started from as pills (the chosen one filled), Save and + at the trailing edge. Below it, the filter rows the +
// adds (Kind, dates, Name, Contents, Size, Tags), each with its pop-ups, its value and its - and + buttons. Measured on
// Finder-Search (tokens files.scope*); the rows have no reference capture (tokens marked estimate).
Item {
    id: root

    required property var app
    // The BrowserTab shown (null: no bar).
    required property var tab

    // Save (the window opens its Save sheet).
    signal saveRequested

    readonly property var query: root.tab !== null && root.tab.fileSearch ? root.tab.searchQuery : ({valid: false})
    readonly property var rows: root.query.valid ? root.query.criteria : []
    readonly property url scopeFolder: root.tab !== null ? root.tab.searchScopeFolder : ""
    readonly property bool inFolder: root.query.valid && String(root.query.folder) !== ""

    visible: root.query.valid
    implicitHeight: visible ? Tokens.filesScopeBarHeight + root.rows.length * Tokens.filesCriteriaRowHeight + Tokens.appsBorderWidth : 0
    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Search scope")

    function folderLabel(folder: url): string {
        const segments = root.app.pathSegments(folder);
        return segments.length > 0 ? DisplayName.text(segments[segments.length - 1].label) : "";
    }

    // A scope pill: bold text, the chosen one on a light fill (Finder-Search).
    component ScopePill: Rectangle {
        id: pill

        property string label: ""
        property bool selected: false
        signal activated

        width: Math.ceil(pillText.implicitWidth + 2 * Tokens.filesScopePillPadding)
        height: Tokens.filesScopePillHeight
        radius: Tokens.filesScopePillRadius
        color: pill.selected ? Appearance.withAlpha(Appearance.colors.text, Tokens.filesScopePillOpacity) : "transparent"
        activeFocusOnTab: true
        Accessible.role: Accessible.RadioButton
        Accessible.name: pill.label
        Accessible.checkable: true
        Accessible.checked: pill.selected
        Accessible.onPressAction: pill.activated()
        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                pill.activated();
                event.accepted = true;
            }
        }

        Text {
            id: pillText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: pill.label
            color: pill.selected ? Appearance.colors.text : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Font.Bold
        }

        FocusRing {
            visible: pill.activeFocus
            shapeRadius: pill.radius
        }

        MouseArea {
            anchors.fill: parent
            onClicked: pill.activated()
        }
    }

    // Save and +: small filled buttons, as tall as the pills.
    component ScopeButton: Rectangle {
        id: button

        property string label: ""
        property string iconName: ""
        property string accessibleName: label
        signal activated

        height: Tokens.filesScopePillHeight
        radius: Tokens.filesScopePillRadius
        color: buttonArea.pressed ? Appearance.withAlpha(Appearance.colors.text, Tokens.filesScopePillOpacity) : Appearance.buttonFill
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: button.accessibleName
        Accessible.onPressAction: button.activated()
        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                button.activated();
                event.accepted = true;
            }
        }

        Text {
            textFormat: Text.PlainText
            visible: button.label !== ""
            anchors.centerIn: parent
            text: button.label
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Icon {
            visible: button.iconName !== ""
            anchors.centerIn: parent
            name: button.iconName
            size: Tokens.menuIconSize
            color: Appearance.colors.text
        }

        FocusRing {
            visible: button.activeFocus
            shapeRadius: button.radius
        }

        MouseArea {
            id: buttonArea
            anchors.fill: parent
            onClicked: button.activated()
        }
    }

    Item {
        id: bar
        width: parent.width
        height: Tokens.filesScopeBarHeight

        Row {
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.filesScopePillGap

            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Search:")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Font.Bold
            }

            ScopePill {
                anchors.verticalCenter: parent.verticalCenter
                label: qsTr("This Computer")
                selected: !root.inFolder
                onActivated: root.tab.setSearchScope("")
            }

            ScopePill {
                anchors.verticalCenter: parent.verticalCenter
                visible: String(root.scopeFolder) !== ""
                label: qsTr("“%1”").arg(root.folderLabel(root.scopeFolder))
                selected: root.inFolder
                onActivated: root.tab.setSearchScope(root.scopeFolder)
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Tokens.filesScopeTrailingInset
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.filesScopeButtonGap

            ScopeButton {
                id: saveButton
                width: Math.ceil(saveMetrics.advanceWidth + 2 * Tokens.filesScopeButtonPadding)
                label: qsTr("Save")
                onActivated: root.saveRequested()

                TextMetrics {
                    id: saveMetrics
                    text: saveButton.label
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }

            ScopeButton {
                width: Tokens.filesScopeAddWidth
                iconName: "plus"
                accessibleName: qsTr("Add a search rule")
                onActivated: root.tab.addCriterion(root.rows.length - 1)
            }
        }
    }

    Column {
        anchors.top: bar.bottom
        width: parent.width

        Repeater {
            model: root.rows

            delegate: CriteriaRow {
                required property var modelData
                required property int index
                width: root.width
                row: modelData
                rowIndex: index
            }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // One filter row: attribute, operator, value (a field, a number and its unit, a date, a kind) and the - and + buttons.
    component CriteriaRow: Item {
        id: criteria

        property var row: ({})
        property int rowIndex: 0
        readonly property var operators: root.app.searchOperators(criteria.row.attribute || "")
        readonly property string valueKind: {
            for (let i = 0; i < criteria.operators.length; i++) {
                if (criteria.operators[i].key === criteria.row.op)
                    return criteria.operators[i].value;
            }
            return "none";
        }
        readonly property bool withUnit: criteria.valueKind === "number"

        height: Tokens.filesCriteriaRowHeight
        Accessible.role: Accessible.Grouping
        Accessible.name: qsTr("Search rule %1").arg(criteria.rowIndex + 1)

        function changed(changes: var): void {
            const next = {attribute: criteria.row.attribute, op: criteria.row.op, value: criteria.row.value, unit: criteria.row.unit};
            for (const key in changes)
                next[key] = changes[key];
            root.tab.setCriterion(criteria.rowIndex, next);
        }

        function asChoices(list: var, key: string, label: string): var {
            return list.map(item => ({id: item[key], text: item[label]}));
        }

        Rectangle {
            width: parent.width
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        Row {
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.spacingSm

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                model: criteria.asChoices(root.app.searchAttributes(), "key", "label")
                value: criteria.row.attribute
                accessibleName: qsTr("Attribute")
                // Another attribute starts from its own defaults (its first operator, its default value and unit).
                onPicked: id => {
                    if (id !== criteria.row.attribute)
                        root.tab.setCriterion(criteria.rowIndex, root.app.searchCriterion(id));
                }
            }

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                model: criteria.asChoices(criteria.operators, "key", "label")
                value: criteria.row.op
                accessibleName: qsTr("Condition")
                onPicked: id => criteria.changed({op: id})
            }

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                visible: criteria.valueKind === "kind"
                model: visible ? criteria.asChoices(root.app.searchKinds(), "key", "label") : []
                value: criteria.row.value
                accessibleName: qsTr("Kind")
                onPicked: id => criteria.changed({value: id})
            }

            TextField {
                id: valueField
                anchors.verticalCenter: parent.verticalCenter
                visible: criteria.valueKind === "text" || criteria.valueKind === "number" || criteria.valueKind === "date" || criteria.valueKind === "tag"
                width: Tokens.filesCriteriaValueWidth
                accessibleName: qsTr("Value")
                text: criteria.valueKind === "date" ? root.app.searchDateText(criteria.row.value || "") : (criteria.row.value || "")
                placeholderText: criteria.valueKind === "date" ? root.app.searchDateText(root.app.searchToday()) : criteria.valueKind === "tag" ? qsTr("Tag name") : ""
                inputMethodHints: criteria.valueKind === "number" ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
                // A row changes once the value is finished (Return, Tab, a click elsewhere): each change is a new search.
                onEditingFinished: {
                    const value = criteria.valueKind === "date" ? root.app.searchDateValue(valueField.text) : valueField.text.trim();
                    if (value !== (criteria.row.value || ""))
                        criteria.changed({value: value});
                }
            }

            ComboBox {
                anchors.verticalCenter: parent.verticalCenter
                visible: criteria.withUnit
                model: visible ? criteria.asChoices(root.app.searchUnits(criteria.row.attribute), "key", "label") : []
                value: criteria.row.unit
                accessibleName: qsTr("Unit")
                onPicked: id => criteria.changed({unit: id})
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Tokens.filesScopeTrailingInset
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tokens.filesScopeButtonGap

            ScopeButton {
                width: Tokens.filesScopeAddWidth
                iconName: "minus"
                accessibleName: qsTr("Remove this search rule")
                onActivated: root.tab.removeCriterion(criteria.rowIndex)
            }

            ScopeButton {
                width: Tokens.filesScopeAddWidth
                iconName: "plus"
                accessibleName: qsTr("Add a search rule")
                onActivated: root.tab.addCriterion(criteria.rowIndex)
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

ColumnLayout {
    id: page

    required property var apps
    required property var vpnRequired
    required property bool excludedMode
    required property bool pending
    required property string errorMessage
    signal backRequested()
    signal modeRequested(bool excluded)
    signal toggleRequested(string appId, bool required)

    function focusSearch() {
        search.forceActiveFocus()
    }

    RowLayout {
        Layout.fillWidth: true

        PlasmaComponents.ToolButton {
            icon.name: "go-previous"
            Accessible.name: "Back to locations"
            onClicked: page.backRequested()
        }

        Kirigami.Heading {
            level: 3
            text: "App routing"
            Layout.fillWidth: true
        }
    }

    RowLayout {
        Layout.fillWidth: true
        PlasmaComponents.Button {
            Layout.fillWidth: true
            text: "VPN-only"
            checked: !page.excludedMode
            onClicked: page.modeRequested(false)
        }
        PlasmaComponents.Button {
            Layout.fillWidth: true
            text: "Excluded"
            checked: page.excludedMode
            onClicked: page.modeRequested(true)
        }
    }

    PlasmaComponents.TextField {
        id: search
        Layout.fillWidth: true
        placeholderText: "Search apps"
        Accessible.name: placeholderText
        onTextChanged: rows.positionViewAtBeginning()
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        text: page.excludedMode ? "Exclude from VPN" : "VPN required"
        font.bold: true
    }

    ListView {
        id: rows

        readonly property string query: search.text.trim().toLowerCase()

        Layout.fillWidth: true
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        Layout.preferredHeight: Layout.minimumHeight
        Layout.maximumHeight: Layout.minimumHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        PlasmaComponents.ScrollBar.vertical: PlasmaComponents.ScrollBar {}
        model: page.apps.filter(app => !query
            || app.name.toLowerCase().includes(query) || app.id.toLowerCase().includes(query))

        delegate: Item {
            id: row

            required property var modelData
            readonly property bool isProtected: !!page.vpnRequired[modelData.id]

            width: rows.width
            height: Math.max(Kirigami.Units.gridUnit * 2, body.implicitHeight)

            RowLayout {
                id: body
                anchors.fill: parent
                anchors.rightMargin: Kirigami.Units.largeSpacing

                PlasmaComponents.Switch {
                    checked: row.isProtected
                    enabled: !page.pending
                    Accessible.name: (page.excludedMode ? "Exclude from VPN: " : "Require VPN: ")
                        + row.modelData.name
                    onToggled: page.toggleRequested(row.modelData.id, checked)
                }

                Kirigami.Icon {
                    source: row.modelData.icon
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                }

                PlasmaComponents.Label {
                    text: row.modelData.name
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

            }
        }

        PlasmaComponents.Label {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: rows.count === 0
            text: page.pending ? "Loading apps…" : search.text.length ? "No matching apps" : "No Flatpak apps found"
        }
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        text: page.errorMessage || (page.excludedMode
            ? "Excluded Flatpaks use the direct connection even when the system kill switch is on."
            : "Flatpak apps. The system kill switch still applies.")
        wrapMode: Text.Wrap
    }
}

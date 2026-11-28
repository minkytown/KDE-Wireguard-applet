import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

ColumnLayout {
    id: page

    required property var apps
    required property var regions
    required property var locations
    signal regionRequested(string appId, string region)
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
        Layout.minimumHeight: Kirigami.Units.gridUnit * 11
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
            height: body.implicitHeight + Kirigami.Units.smallSpacing

            ColumnLayout {
                id: body
                anchors.fill: parent
                anchors.rightMargin: Kirigami.Units.largeSpacing

                RowLayout {
                Layout.fillWidth: true
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
                PlasmaComponents.ComboBox {
                    Layout.fillWidth: true
                    visible: row.isProtected && !page.excludedMode
                    enabled: !page.pending
                    model: page.locations
                    textRole: "name"
                    currentIndex: Math.max(0, page.locations.findIndex(location => location.id === (page.regions[row.modelData.id] || "host")))
                    Accessible.name: "VPN location for " + row.modelData.name
                    onActivated: index => page.regionRequested(row.modelData.id, page.locations[index].id)
                }
            }
        }

        PlasmaComponents.Label {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: rows.count === 0
            text: page.pending ? "Loading apps…" : search.text.length ? "No matching apps" : "No apps found"
        }
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        text: page.errorMessage || (page.excludedMode
            ? "Excluded apps use the direct connection even when the system kill switch is on."
            : "Native and Flatpak apps. Running apps prompt to close and reopen with the new route.")
        wrapMode: Text.Wrap
    }
}

import QtQuick
import QtCore
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    readonly property string helper: {
        const home = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString()
        const path = decodeURIComponent(home.replace(/^file:\/\//, ""))
            + "/.local/share/pia-vopono/bin/walker-vpn"
        return "'" + path.replace(/'/g, "'\\''") + "'"
    }
    property string connectionStatus: "Checking status"
    property var locations: []
    property string catalogError: ""
    property string killSwitchStatus: "Checking"
    property string killSwitchError: ""
    property bool killSwitchPending: false
    property string bootReconnectStatus: "Checking"
    property string bootReconnectError: ""
    property bool bootReconnectPending: false
    property bool appsVisible: false
    property bool appsPending: false
    property var applications: []
    property var requiredApps: ({})
    property var excludedApps: ({})
    property var appRegions: ({})
    property bool exclusionsVisible: false
    property string appCatalogKey: ""
    property string appsError: ""
    readonly property bool disconnected: connectionStatus === "Disconnected"
    readonly property bool busy: connectionStatus.startsWith("Connecting")
        || connectionStatus.startsWith("Checking")

    toolTipMainText: "PIA WireGuard"
    toolTipSubText: connectionStatus
    preferredRepresentation: compactRepresentation
    Layout.minimumWidth: Plasmoid.formFactor === PlasmaCore.Types.Horizontal ? 48 : -1
    Layout.preferredWidth: Layout.minimumWidth
    onExpandedChanged: () => {
        if (root.expanded)
            catalogSource.connectSource(helper + " locations-json")
        else
            root.appsVisible = false
    }

    function run(action) {
        launcher.connectSource(helper + " " + action)
    }

    function switchTo(region) {
        if (/^[a-zA-Z0-9_-]{1,64}$/.test(region)) {
            run("system-connect --region " + region)
            expanded = false
        }
    }

    function appsRequest(command) {
        if (appsPending)
            return
        appsError = ""
        appsPending = true
        appsSource.connectSource(helper + " " + command)
    }

    function isAppId(id) {
        return /^[a-zA-Z0-9_.][a-zA-Z0-9_.-]{0,199}$/.test(id)
    }

    Plasma5Support.DataSource {
        id: appsSource
        engine: "executable"
        onNewData: (sourceName, data) => {
            appsSource.disconnectSource(sourceName)
            try {
                if (Number(data["exit code"]) !== 0)
                    throw new Error()
                const response = JSON.parse(data.stdout)
                if (Array.isArray(response.apps)) {
                    const catalog = response.apps.map(app => ({
                        id: app.id, name: app.name, icon: app.icon
                    }))
                    const key = JSON.stringify(catalog)
                    if (root.appCatalogKey !== key) {
                        root.appCatalogKey = key
                        root.applications = catalog
                    }
                    const requirements = {}
                    const exclusions = {}
                    const regions = {}
                    for (const app of response.apps) {
                        requirements[app.id] = app.required
                        exclusions[app.id] = app.excluded
                        regions[app.id] = app.region || "host"
                    }
                    root.requiredApps = requirements
                    root.excludedApps = exclusions
                    root.appRegions = regions
                }
                root.appsError = response.error || ""
            } catch (error) {
                root.appsError = "Could not update app routing."
            }
            root.appsPending = false
        }
    }

    Plasma5Support.DataSource {
        id: catalogSource
        engine: "executable"
        onNewData: (sourceName, data) => {
            catalogSource.disconnectSource(sourceName)
            if (Number(data["exit code"]) === 0) {
                try {
                    root.locations = JSON.parse(data.stdout)
                    root.catalogError = ""
                } catch (error) {
                    root.catalogError = "Location catalog could not be read."
                }
            } else {
                root.catalogError = "Location catalog is unavailable."
            }
        }
    }

    Plasma5Support.DataSource {
        id: statusSource
        engine: "executable"
        connectedSources: [root.helper + " panel-status"]
        interval: 2500
        onNewData: (sourceName, data) => {
            try {
                if (Number(data["exit code"]) !== 0)
                    throw new Error()
                const status = JSON.parse(data.stdout)
                root.connectionStatus = status.connection
                root.killSwitchStatus = status.killSwitch
                root.bootReconnectStatus = status.bootReconnect || "Unavailable"
            } catch (error) {
                root.connectionStatus = "Status unavailable"
                root.killSwitchStatus = "Unavailable"
                root.bootReconnectStatus = "Unavailable"
            }
        }
    }

    Plasma5Support.DataSource {
        id: launcher
        engine: "executable"
        onNewData: (sourceName, data) => launcher.disconnectSource(sourceName)
    }

    Plasma5Support.DataSource {
        id: killSwitchCommand
        engine: "executable"
        onNewData: (sourceName, data) => {
            killSwitchCommand.disconnectSource(sourceName)
            if (Number(data["exit code"]) === 0)
                root.killSwitchStatus = sourceName.endsWith(" on") ? "On" : "Off"
            else
                root.killSwitchError = "Could not change the system kill switch."
            root.killSwitchPending = false
        }
    }

    Plasma5Support.DataSource {
        id: bootReconnectCommand
        engine: "executable"
        onNewData: (sourceName, data) => {
            bootReconnectCommand.disconnectSource(sourceName)
            if (Number(data["exit code"]) === 0)
                root.bootReconnectStatus = sourceName.endsWith(" on") ? "On" : "Off"
            else
                root.bootReconnectError = "Could not change reconnect on reboot."
            root.bootReconnectPending = false
        }
    }

    compactRepresentation: PlasmaComponents.Button {
        Layout.minimumWidth: implicitWidth
        Layout.preferredWidth: implicitWidth
        text: "PIA"
        font.bold: !root.disconnected
        checkable: false
        Accessible.name: "PIA WireGuard"
        Accessible.description: root.connectionStatus
        onClicked: root.expanded = !root.expanded
    }

    fullRepresentation: Loader {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredWidth: Kirigami.Units.gridUnit * 21
        Layout.minimumHeight: item ? Math.min(item.implicitHeight, Kirigami.Units.gridUnit * 18) : 0
        Layout.preferredHeight: Layout.minimumHeight
        Layout.maximumHeight: Layout.minimumHeight
        sourceComponent: root.appsVisible ? appView : locationView
        onLoaded: {
            if (root.appsVisible)
                Qt.callLater(item.focusSearch)
        }
    }

    Component {
        id: locationView
        ColumnLayout {
            id: chooser

            readonly property string query: search.text.trim().toLowerCase()

            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: root.connectionStatus
                wrapMode: Text.Wrap
            }

            PlasmaComponents.Switch {
                Layout.fillWidth: true
                text: root.killSwitchStatus === "Degraded" ? "System kill switch needs attention" : root.killSwitchStatus === "Unavailable"
                    ? "System kill switch unavailable" : "System kill switch"
                checked: root.killSwitchStatus === "On" || root.killSwitchStatus === "Degraded"
                enabled: !root.killSwitchPending
                    && (root.killSwitchStatus === "On" || root.killSwitchStatus === "Off" || root.killSwitchStatus === "Degraded")
                onToggled: {
                    root.killSwitchError = ""
                    root.killSwitchPending = true
                    killSwitchCommand.connectSource(root.helper + " kill-switch-set " + (checked ? "on" : "off"))
                }
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.killSwitchError.length > 0
                text: root.killSwitchError
                wrapMode: Text.Wrap
            }

            PlasmaComponents.Switch {
                Layout.fillWidth: true
                text: "Reconnect on reboot"
                checked: root.bootReconnectStatus === "On"
                enabled: !root.bootReconnectPending
                    && (root.bootReconnectStatus === "On" || root.bootReconnectStatus === "Off")
                onToggled: {
                    root.bootReconnectError = ""
                    root.bootReconnectPending = true
                    bootReconnectCommand.connectSource(root.helper + " boot-reconnect-set "
                        + (checked ? "on" : "off"))
                }
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.bootReconnectError.length > 0
                text: root.bootReconnectError
                wrapMode: Text.Wrap
            }

            PlasmaComponents.TextField {
                id: search
                Layout.fillWidth: true
                placeholderText: "Search countries or locations"
                Accessible.name: placeholderText
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.catalogError.length > 0
                text: root.catalogError
                wrapMode: Text.Wrap
            }

            ListView {
                id: regionList
                Layout.fillWidth: true
                Layout.minimumHeight: Kirigami.Units.gridUnit * 7
                Layout.preferredHeight: Layout.minimumHeight
                Layout.maximumHeight: Layout.minimumHeight
                enabled: !root.busy
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                PlasmaComponents.ScrollBar.vertical: PlasmaComponents.ScrollBar {}
                model: root.locations.filter(item => item.id === "optimal"
                    || [item.name, item.country, item.code].join(" ").toLowerCase().includes(chooser.query))
                delegate: PlasmaComponents.ItemDelegate {
                    required property var modelData
                    width: regionList.width
                    text: modelData.name + "  ·  " + modelData.country
                    onClicked: root.switchTo(modelData.id)
                }
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    text: "App routing…"
                    onClicked: {
                        root.appsVisible = true
                        root.appsRequest("app-list-json")
                    }
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    text: "Disconnect"
                    enabled: (!root.disconnected || root.killSwitchStatus === "On") && !root.busy
                        && root.connectionStatus !== "Status unavailable"
                    onClicked: {
                        root.run("system-disconnect")
                        root.expanded = false
                    }
                }
                PlasmaComponents.Button {
                    Layout.fillWidth: true
                    text: "PIA Credentials…"
                    enabled: !root.busy
                    onClicked: {
                        root.run("credentials")
                        root.expanded = false
                    }
                }
            }
        }
    }

    Component {
        id: appView
        AppList {
            apps: root.applications
            vpnRequired: root.exclusionsVisible ? root.excludedApps : root.requiredApps
            excludedMode: root.exclusionsVisible
            regions: root.appRegions
            locations: [{id: "host", name: "Follow system VPN"}].concat(root.locations)
            pending: root.appsPending
            errorMessage: root.appsError
            onBackRequested: root.appsVisible = false
            onModeRequested: excluded => {
                root.exclusionsVisible = excluded
                root.appsError = ""
            }
            onRegionRequested: (appId, region) => {
                if (root.isAppId(appId) && /^[a-zA-Z0-9_-]{1,64}$/.test(region))
                    root.appsRequest("app-set-json " + appId + " on --mode vpn " + region)
            }
            onToggleRequested: (appId, required) => {
                if (root.isAppId(appId))
                    root.appsRequest("app-set-json " + appId + (required ? " on" : " off")
                        + (root.exclusionsVisible ? " --mode direct" : " --mode vpn " + (root.appRegions[appId] || "host")))
            }
        }
    }
}

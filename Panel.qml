import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Centered, full-screen dashboard summoned by clicking the bar widget.
// Rendered as one overlay window so it can sit in the middle of the screen
// instead of hanging off the bar like a regular popup.
Item {
  id: root

  property QtObject bar: null
  property var settings: ({})
  property var anchorItem: null
  property var hostWidget: null

  property bool opened: false
  property var snapshot: null
  property bool firstSyncDone: false
  property bool connectRequested: false
  property bool connecting: false
  property bool demoMode: false
  property string keyError: ""
  property int nowTick: 0
  property bool confirmDisconnect: false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property var barIdentity: hostWidget || root
  readonly property bool popoutSwitchClosing: false

  readonly property var week: (snapshot && snapshot.week) ? snapshot.week : null
  readonly property var user: (snapshot && snapshot.user) ? snapshot.user : null
  readonly property var recent: (snapshot && snapshot.recent) ? snapshot.recent : []
  readonly property var history: (snapshot && snapshot.history) ? snapshot.history : []
  readonly property var muscles: (snapshot && snapshot.muscles) ? snapshot.muscles : []
  readonly property var records: (snapshot && snapshot.records) ? snapshot.records : []

  // Overview is the original dashboard; the other tabs read snapshot.deep.
  property string tab: "overview"
  readonly property var deep: (snapshot && snapshot.deep && !snapshot.deep.error) ? snapshot.deep : null
  readonly property var dd: deep ? deep : ({
    window_weeks: 16, sessions_in_window: 0, insights: [], progression: [], prs: [],
    patterns: { weekday: [], time_of_day: [], rep_ranges: [] }, weekly_sets: { weeks: [], rows: [] },
    duration_weeks: [], balance: {}, recent: [], averages: {}
  })
  readonly property real gridLabelW: Style.space(78)
  readonly property real gridAvgW: Style.space(70)
  readonly property var calendar: (snapshot && snapshot.calendar) ? snapshot.calendar : []
  readonly property real avgSessions: {
    if (history.length === 0) return 0
    var total = 0
    for (var i = 0; i < history.length; i++) total += history[i].workouts || 0
    return total / history.length
  }
  readonly property real calendarPeak: {
    var peak = 0
    for (var i = 0; i < calendar.length; i++) {
      var v = calendar[i].volume_kg || 0
      if (v > peak) peak = v
    }
    return peak
  }
  readonly property var totals: (snapshot && snapshot.totals) ? snapshot.totals : null
  readonly property var body: (snapshot && snapshot.body) ? snapshot.body : null

  readonly property bool authenticated: Model.hasData(snapshot)
  readonly property bool isDemo: !!(snapshot && snapshot.demo)
  readonly property bool stale: !!(snapshot && snapshot.stale)
  readonly property bool showConnect: root.connectRequested || (root.firstSyncDone && Model.isAuthError(root.snapshot))
  readonly property bool showError: root.firstSyncDone && !!(snapshot && snapshot.error === "network")
  readonly property bool showLoading: !root.firstSyncDone && !root.connectRequested && !root.authenticated

  readonly property string unit: Model.unitOf(snapshot)
  readonly property var weekVolume: Model.volumeParts(week ? week.volume_kg : 0, unit)
  readonly property bool hasWeekVolume: !!(week && week.volume_kg > 0)
  readonly property string heroValue: root.hasWeekVolume
    ? root.weekVolume.value
    : String(week ? week.workouts : 0)
  readonly property string heroUnit: root.hasWeekVolume
    ? root.weekVolume.unit
    : (week && week.workouts === 1 ? "session" : "sessions")
  readonly property string barLabel: {
    if (!root.authenticated || !week) return "—"
    if (week.volume_kg > 0) return Model.volumeShort(week.volume_kg, root.unit)
    return week.workouts + "×"
  }
  readonly property string syncLabel: {
    root.nowTick
    if (root.isDemo) return "SAMPLE DATA"
    if (!snapshot || !snapshot.fetched_at) return ""
    var rel = Model.relativeUpdated(snapshot.fetched_at, root.nowSeconds)
    return (root.stale ? "STALE · " : "SYNCED ") + rel.toUpperCase()
  }
  readonly property real nowSeconds: {
    root.nowTick
    return Date.now() / 1000
  }

  readonly property real targetFraction: {
    if (!week || !week.target) return 0
    return Math.max(0, Math.min(1, week.workouts / week.target))
  }
  readonly property var dayHeights: Model.barHeights(
    week ? week.days.map(function(d) { return d.volume_kg }) : [], 26)

  readonly property color hevyBlue: "#1D83EA"
  readonly property color hevySky: "#5AB4FF"
  readonly property color hevyAmber: "#FF9D28"
  readonly property color hevyGreen: "#5FD08A"
  readonly property color hevyRose: "#E5678A"
  readonly property color hevyViolet: "#A48CF0"
  readonly property color dim: Util.alpha(root.barForeground, 0.58)
  readonly property color faint: Util.alpha(root.barForeground, 0.34)
  readonly property color line: Util.alpha(root.barForeground, 0.10)
  readonly property color cardBg: Util.alpha(root.barForeground, 0.045)
  readonly property color track: Util.alpha(root.barForeground, 0.09)
  readonly property var muscleColors: [hevyBlue, hevySky, hevyGreen, hevyAmber, hevyViolet, hevyRose, faint]
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string firstName: {
    var name = user ? String(user.name || "") : ""
    return name.split(" ")[0] || "Athlete"
  }
  readonly property string deltaText: week ? Model.deltaLabel(week.change_pct) : ""
  readonly property bool deltaUp: !!(week && week.change_pct !== null && week.change_pct >= 0)


  function switchPanel(direction) { return false }

  function open() {
    root.opened = true
    if (!root.demoMode) root.refresh(false)
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  function heatAlpha(volume) {
    if (!volume || volume <= 0 || root.calendarPeak <= 0) return 0
    return 0.22 + 0.78 * Math.min(1, Math.sqrt(volume / root.calendarPeak))
  }

  function binCommand(name) {
    return ["python3", root.pluginDir + "bin/" + name]
  }

  function refresh(force) {
    if (syncProc.running) return
    syncProc.command = root.binCommand("hevy-sync.py").concat(force ? ["--force"] : [])
    syncProc.running = true
  }

  function previewDemo() {
    root.demoMode = true
    if (demoProc.running) return
    demoProc.running = true
  }

  function submitKey() {
    var key = keyField.text.trim()
    if (key === "") {
      root.keyError = "Paste your Hevy API key first."
      return
    }
    root.keyError = ""
    root.connecting = true
    keyProc.pendingKey = key
    keyProc.running = true
  }

  function askDisconnect() {
    if (root.isDemo) {
      root.demoMode = false
      root.connectRequested = true
      root.snapshot = null
      return
    }
    root.confirmDisconnect = true
  }

  function disconnect() {
    root.confirmDisconnect = false
    if (clearProc.running) return
    clearProc.running = true
  }

  Shortcut {
    sequence: "Escape"
    enabled: root.opened && !root.confirmDisconnect
    onActivated: root.close()
  }

  IpcHandler {
    target: "fbaroni.oma-hevy"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function demo(): void { root.previewDemo(); root.open() }
    function tab(name: string): void { if (["overview", "progress", "patterns", "history"].indexOf(name) >= 0) root.tab = name }
    function scroll(offset: string): void { deepScroller.contentY = Math.max(0, parseFloat(offset) || 0) }
  }

  Process {
    id: syncProc
    command: root.binCommand("hevy-sync.py")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSnapshot(text)
        if (parsed && !root.demoMode) root.snapshot = parsed
        root.firstSyncDone = true
      }
    }
    onExited: function(exitCode) {
      if (!root.firstSyncDone) {
        root.snapshot = { error: "network", message: "Hevy sync failed (exit " + exitCode + ")." }
        root.firstSyncDone = true
      }
    }
  }

  Process {
    id: demoProc
    command: root.binCommand("hevy-sync.py").concat(["--demo"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSnapshot(text)
        if (parsed) {
          root.snapshot = parsed
          root.demoMode = true
          root.firstSyncDone = true
          root.connectRequested = false
        }
      }
    }
  }

  Process {
    id: keyProc
    property string pendingKey: ""
    property string errorText: ""
    command: root.binCommand("hevy-key.py").concat(["save"])
    stdinEnabled: true
    onStarted: {
      write(pendingKey + "\n")
      pendingKey = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: keyProc.errorText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.connecting = false
      if (exitCode !== 0) {
        root.keyError = keyProc.errorText || "Hevy could not verify that key."
        return
      }
      keyField.text = ""
      root.keyError = ""
      root.demoMode = false
      root.connectRequested = false
      root.firstSyncDone = false
      root.refresh(true)
    }
  }

  Process {
    id: clearProc
    command: root.binCommand("hevy-key.py").concat(["clear"])
    onExited: function(exitCode) {
      root.snapshot = { error: "not_authenticated" }
      root.firstSyncDone = true
      root.connectRequested = true
    }
  }

  Process {
    id: openProc
    command: ["xdg-open", "https://hevy.com/settings?developer"]
  }

  Timer {
    interval: 20 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowTick++
  }

  // ----------------------------------------------------------- the overlay

  PanelWindow {
    id: win
    visible: root.opened
    color: "transparent"
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-oma-hevy"
    WlrLayershell.layer: WlrLayer.Overlay
    // Prime with Exclusive for a beat on every open so the layer surface
    // actually receives keys while it maps, then settle on OnDemand.
    property bool focusPrimed: false
    WlrLayershell.keyboardFocus: root.opened
      ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onBackingWindowVisibleChanged: if (root.opened) primeTimer.restart()

    Timer {
      id: primeTimer
      interval: 140
      onTriggered: {
        win.focusPrimed = true
        keyFocus.forceActiveFocus()
      }
    }

    Item {
      id: keyFocus
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: if (!root.confirmDisconnect) root.close()
      Keys.onPressed: function(event) {
        if (!root.authenticated || root.showConnect) return
        var keys = [Qt.Key_1, Qt.Key_2, Qt.Key_3, Qt.Key_4]
        var tabs = ["overview", "progress", "patterns", "history"]
        var i = keys.indexOf(event.key)
        if (i >= 0 && (i === 0 || root.deep !== null)) root.tab = tabs[i]
      }
    }

    // Dimmed backdrop; clicking anywhere outside the card dismisses.
    Rectangle {
      anchors.fill: parent
      color: "#000000"
      opacity: 0.5

      MouseArea {
        anchors.fill: parent
        onClicked: if (!root.confirmDisconnect) root.close()
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      // Designed at a fixed size, then scaled up to fill the screen. Override
      // with `omarchy bar set <plugin-id> scale 1.3 --json` (it never exceeds
      // the screen).
      readonly property real baseW: Style.space(1000)
      readonly property real baseH: Style.space(800)
      readonly property real fit: Math.min((parent.width - Style.space(48)) / baseW,
                                           (parent.height - Style.space(48)) / baseH)
      readonly property real wanted: (root.settings && Number(root.settings.scale) > 0)
        ? Number(root.settings.scale) : 1.5
      width: baseW
      height: baseH
      scale: Math.max(0.5, Math.min(wanted, fit))
      transformOrigin: Item.Center
      radius: Math.max(8, Style.cornerRadius)
      color: Color.popups.background
      border.width: 1
      border.color: Util.alpha(root.hevyBlue, 0.42)

      // Swallow clicks so they never reach the dismissal surface.
      MouseArea { anchors.fill: parent }

      // Thin Hevy-blue accent along the top edge of the card.
      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: -1
        height: Style.space(3)
        radius: height / 2
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 0.28; color: root.hevyBlue }
          GradientStop { position: 0.72; color: root.hevySky }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      Item {
        id: cardContent
        anchors.fill: parent
        anchors.margins: Style.space(24)

        Column {
          id: cardColumn
          anchors.fill: parent
          spacing: Style.space(14)

          // ------------------------------------------------------- header
          Item {
            id: header
            width: parent.width
            height: Style.space(38)

            Image {
              id: logo
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              height: Style.space(30)
              source: "hevy-mark-blue.svg"
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Math.round(width * Screen.devicePixelRatio)
              sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            }

            Column {
              anchors.left: logo.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                text: "HEVY"
                color: root.hevySky
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 3
              }
              Text {
                text: root.authenticated ? root.firstName : "Not connected"
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Rectangle {
                visible: root.isDemo
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(18)
                width: demoLabel.implicitWidth + Style.space(12)
                radius: height / 2
                color: Util.alpha(root.hevyAmber, 0.16)

                Text {
                  id: demoLabel
                  anchors.centerIn: parent
                  text: "SAMPLE DATA"
                  color: root.hevyAmber
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.6
                }
              }

              Text {
                visible: !root.showConnect && !root.showLoading && !root.isDemo && root.syncLabel !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.syncLabel
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 0.8
              }

              Button {
                visible: !root.showConnect && !root.showLoading
                iconText: ""
                tooltipText: "Refresh"
                foreground: root.barForeground
                accent: root.hevySky
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(7)
                verticalPadding: Style.space(5)
                onClicked: root.refresh(true)
              }

              Button {
                iconText: ""
                tooltipText: "Close"
                foreground: root.barForeground
                accent: root.hevySky
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(7)
                verticalPadding: Style.space(5)
                onClicked: root.close()
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.line
          }

          // ---------------------------------------------------------- tabs
          Item {
            id: tabBar
            width: parent.width
            height: Style.space(26)
            visible: root.authenticated && !root.showConnect

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: [
                  { key: "overview", label: "Overview" },
                  { key: "progress", label: "Progress" },
                  { key: "patterns", label: "Patterns" },
                  { key: "history", label: "History" }
                ]

                Rectangle {
                  id: tabChip
                  required property var modelData
                  readonly property bool active: root.tab === modelData.key
                  readonly property bool ready: modelData.key === "overview" || root.deep !== null
                  width: tabLabel.implicitWidth + Style.space(22)
                  height: Style.space(22)
                  radius: height / 2
                  color: active ? Util.alpha(root.hevyBlue, 0.22) : "transparent"
                  border.width: 1
                  border.color: active ? root.hevySky : root.line
                  opacity: ready ? 1 : 0.4

                  Text {
                    id: tabLabel
                    anchors.centerIn: parent
                    text: tabChip.modelData.label
                    color: tabChip.active ? root.hevySky : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: tabChip.active
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: tabChip.ready
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.tab = tabChip.modelData.key
                  }
                }
              }
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.deep === null && root.authenticated && !root.isDemo ? "refresh (⟳) to load the extra tabs" : "keys 1–4 · wheel scrolls"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // --------------------------------------------------------- body
          Item {
            id: body
            width: parent.width
            height: cardColumn.height - header.height - tabBar.height - footer.height - Style.spacing.hairline
              - cardColumn.spacing * 4

            // Connect / loading / error all share the centered state view.
            Column {
              visible: root.showConnect || root.showLoading || root.showError
              anchors.centerIn: parent
              width: Math.min(parent.width, Style.space(560))
              spacing: Style.space(12)

              Text {
                visible: root.showLoading
                text: "Loading Hevy…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
              }

              Image {
                visible: root.showConnect
                width: Style.space(48)
                height: Style.space(42)
                source: "hevy-mark-blue.svg"
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
              }

              Text {
                visible: root.showConnect
                text: "Your training, on the desktop."
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                visible: root.showConnect
                width: parent.width
                text: "Paste a Hevy API key to pull your workouts, weekly volume, muscle balance and top lifts. Works with Hevy Pro; create a key at hevy.com/settings?developer."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }

              TextField {
                id: keyField
                visible: root.showConnect
                width: parent.width
                placeholderText: "Hevy API key"
                password: true
                foreground: root.barForeground
                accent: root.hevySky
                enabled: !root.connecting
                onTextChanged: if (!root.connecting) root.keyError = ""
                Keys.onReturnPressed: root.submitKey()
              }

              Text {
                visible: root.showConnect && root.keyError !== ""
                width: parent.width
                text: Model.truncate(root.keyError, 200)
                color: root.hevyRose
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Row {
                visible: root.showConnect
                spacing: Style.space(10)

                Button {
                  text: root.connecting ? "Checking…" : "Connect Hevy"
                  bordered: true
                  foreground: root.barForeground
                  accent: root.hevyBlue
                  fontFamily: root.fontFamily
                  iconText: root.connecting ? "" : ""
                  iconSpinning: root.connecting
                  enabled: !root.connecting
                  onClicked: root.submitKey()
                }

                Button {
                  text: "Preview sample"
                  foreground: root.dim
                  accent: root.hevySky
                  fontFamily: root.fontFamily
                  enabled: !root.connecting
                  onClicked: root.previewDemo()
                }

                Button {
                  text: "Get a key"
                  foreground: root.dim
                  accent: root.hevySky
                  fontFamily: root.fontFamily
                  onClicked: openProc.running = true
                }
              }

              Text {
                visible: root.showConnect
                width: parent.width
                text: "Stored locally in ~/.config/omarchy/hevy/config.json (chmod 600). Nothing leaves this machine except calls to api.hevyapp.com."
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Text {
                visible: root.showError
                text: "Can't reach Hevy"
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }
              Text {
                visible: root.showError
                width: parent.width
                text: snapshot && snapshot.message ? Model.truncate(snapshot.message, 220) : "Check your connection and try again."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
              }
              Row {
                visible: root.showError
                spacing: Style.space(10)
                Button {
                  text: "Retry"
                  bordered: true
                  foreground: root.barForeground
                  accent: root.hevyBlue
                  fontFamily: root.fontFamily
                  onClicked: root.refresh(true)
                }
                Button {
                  text: "Use a different key"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  onClicked: root.connectRequested = true
                }
              }
            }

            // ------------------------------------------------ dashboard grid
            Row {
              visible: root.authenticated && !root.showConnect && root.tab === "overview"
              anchors.fill: parent
              spacing: Style.space(18)

              Column {
                id: leftColumn
                width: (parent.width - parent.spacing) * 0.46
                spacing: Style.space(12)

                // Hero card
                Rectangle {
                  width: parent.width
                  height: Style.space(132)
                  radius: Math.max(6, Style.cornerRadius)
                  border.width: 1
                  border.color: Util.alpha(root.hevyBlue, 0.4)
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Util.alpha(root.hevyBlue, 0.24) }
                    GradientStop { position: 0.62; color: Util.alpha(root.hevyBlue, 0.07) }
                    GradientStop { position: 1.0; color: Util.alpha(root.hevyBlue, 0.02) }
                  }

                  Item {
                    anchors.fill: parent
                    anchors.margins: Style.space(14)

                    Column {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Text {
                        text: root.hasWeekVolume ? "THIS WEEK · VOLUME" : "THIS WEEK · SESSIONS"
                        color: Util.alpha(root.hevySky, 0.92)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1.3
                        font.bold: true
                      }

                      Row {
                        spacing: Style.space(6)

                        Text {
                          text: root.heroValue
                          color: root.barForeground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.displayLarge
                          font.bold: true
                        }
                        Text {
                          text: root.heroUnit
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.title
                          topPadding: Style.space(10)
                        }
                      }

                      Row {
                        spacing: Style.space(8)

                        Rectangle {
                          visible: root.deltaText !== "" && root.hasWeekVolume
                          height: Style.space(18)
                          width: deltaLabelText.implicitWidth + Style.space(12)
                          radius: height / 2
                          color: Util.alpha(root.deltaUp ? root.hevyGreen : root.hevyRose, 0.16)

                          Text {
                            id: deltaLabelText
                            anchors.centerIn: parent
                            text: root.deltaText
                            color: root.deltaUp ? root.hevyGreen : root.hevyRose
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: (week ? week.workouts : 0) + (week && week.workouts === 1 ? " session" : " sessions")
                            + " · " + (week ? week.sets : 0)
                            + (week && week.sets === 1 ? " set" : " sets")
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Text {
                        text: Model.durationLabel(week ? week.duration_s : 0) + " trained · "
                          + ((week ? week.reps : 0) > 0 ? (week.reps + " reps") : "cardio / mobility")
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Column {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      TargetRing {
                        anchors.horizontalCenter: parent.horizontalCenter
                        done: week ? week.workouts : 0
                        target: week ? week.target : 4
                      }

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "SESSIONS"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                      }
                    }
                  }
                }

                // Week strip
                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: Style.space(14)

                    Text {
                      anchors.left: parent.left
                      text: "WEEK"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1.3
                    }
                    Text {
                      anchors.right: parent.right
                      text: (week ? week.target : 0) + "× TARGET · "
                        + (snapshot ? snapshot.streak_weeks : 0) + " WEEK STREAK"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 0.6
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: root.week ? root.week.days : []

                      Item {
                        id: dayCell
                        required property var modelData
                        required property int index
                        width: (parent.width - Style.space(4) * 6) / 7
                        height: Style.space(48)

                        Rectangle {
                          anchors.horizontalCenter: parent.horizontalCenter
                          y: parent.height - Style.space(14) - height
                          width: Math.max(4, parent.width * 0.5)
                          height: Math.max(dayCell.modelData.workouts > 0 ? Style.space(4) : Style.spacing.hairline,
                            root.dayHeights[dayCell.index] || 0)
                          radius: Math.min(width / 2, Style.space(3))
                          color: dayCell.modelData.workouts > 0 ? root.hevyBlue : root.track
                          opacity: dayCell.modelData.is_future ? 0.35 : 1
                        }

                        Text {
                          anchors.horizontalCenter: parent.horizontalCenter
                          anchors.bottom: parent.bottom
                          text: Model.weekdayLabel(dayCell.modelData.date)
                          color: dayCell.modelData.is_today ? root.hevySky : root.faint
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: dayCell.modelData.is_today
                        }

                        Rectangle {
                          visible: dayCell.modelData.is_today
                          anchors.horizontalCenter: parent.horizontalCenter
                          anchors.bottom: parent.bottom
                          anchors.bottomMargin: -Style.space(4)
                          width: Style.space(3)
                          height: Style.space(3)
                          radius: width / 2
                          color: root.hevySky
                        }
                      }
                    }
                  }
                }

                // Recent sessions
                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "RECENT SESSIONS"
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.3
                  }

                  Rectangle {
                    width: parent.width
                    height: recentColumn.implicitHeight + Style.space(4)
                    radius: Math.max(6, Style.cornerRadius)
                    color: root.cardBg

                    Column {
                      id: recentColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter

                      Repeater {
                        model: root.recent.slice(0, 3)

                        Item {
                          id: recentRow
                          required property var modelData
                          required property int index
                          width: recentColumn.width
                          height: Style.space(54)

                          Rectangle {
                            visible: recentRow.index > 0
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            height: Style.spacing.hairline
                            color: root.line
                          }

                          Column {
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0
                            width: parent.width * 0.56

                            Text {
                              width: parent.width
                              text: recentRow.modelData.title
                              color: root.barForeground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.body
                              font.bold: true
                              elide: Text.ElideRight
                            }
                            Text {
                              text: Model.dateLabel(recentRow.modelData.start)
                                + " · " + (recentRow.modelData.sets || 0)
                                + (recentRow.modelData.sets === 1 ? " set" : " sets")
                                + " · " + Model.durationLabel(recentRow.modelData.duration_s)
                              color: root.faint
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }

                          Column {
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0
                            width: parent.width * 0.4

                            Text {
                              anchors.right: parent.right
                              text: recentRow.modelData.volume_kg > 0
                                ? Model.volumeShort(recentRow.modelData.volume_kg, root.unit)
                                : "—"
                              color: root.barForeground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.body
                              font.bold: true
                            }
                            Text {
                              anchors.right: parent.right
                              width: parent.width
                              horizontalAlignment: Text.AlignRight
                              text: recentRow.modelData.best
                                ? recentRow.modelData.best.title + " "
                                  + Model.weightLabel(recentRow.modelData.best.weight_kg, root.unit)
                                : ""
                              color: root.faint
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }
                          }
                        }
                      }

                      Text {
                        visible: root.recent.length === 0
                        width: parent.width
                        height: Style.space(44)
                        text: "No sessions logged yet."
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: Style.space(10)
                      }
                    }
                  }
                }


                // Consistency heatmap
                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: Style.space(14)

                    Text {
                      anchors.left: parent.left
                      text: "CONSISTENCY"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1.3
                    }
                    Text {
                      anchors.right: parent.right
                      text: "LAST 12 WEEKS"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 0.6
                    }
                  }

                  Row {
                    width: parent.width
                    height: Style.space(112)
                    spacing: Style.space(14)

                    Grid {
                      columns: 12
                      rows: 7
                      columnSpacing: Style.space(3)
                      rowSpacing: Style.space(3)

                      Repeater {
                        model: root.calendar

                        Rectangle {
                          id: heatCell
                          required property var modelData
                          width: Style.space(13)
                          height: Style.space(13)
                          radius: Style.space(3)
                          color: heatCell.modelData.future
                            ? "transparent"
                            : (heatCell.modelData.workouts > 0
                              ? Util.alpha(root.hevyBlue, root.heatAlpha(heatCell.modelData.volume_kg))
                              : root.track)
                          opacity: heatCell.modelData.future ? 0.22 : 1
                          border.width: heatCell.modelData.future ? 1 : 0
                          border.color: root.track
                        }
                      }
                    }

                    Column {
                      y: (parent.height - height) / 2
                      spacing: Style.space(5)

                      Text {
                        text: "DAILY VOLUME"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 0.6
                      }

                      Row {
                        spacing: Style.space(3)
                        Repeater {
                          model: [0.0, 0.25, 0.45, 0.65, 0.85, 1.0]
                          Rectangle {
                            required property var modelData
                            width: Style.space(9)
                            height: Style.space(9)
                            radius: Style.space(2)
                            color: modelData === 0 ? root.track : Util.alpha(root.hevyBlue, modelData)
                          }
                        }
                      }

                      Text {
                        text: (snapshot ? snapshot.streak_weeks : 0) + " week streak"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  StatCell {
                    width: (parent.width - Style.space(18)) / 4
                    label: "STREAK"
                    value: (snapshot ? snapshot.streak_weeks : 0) + " wk"
                  }
                  StatCell {
                    width: (parent.width - Style.space(18)) / 4
                    label: "LAST"
                    value: {
                      var days = snapshot ? snapshot.days_since_last : null
                      if (days === null || days === undefined) return "—"
                      if (days === 0) return "today"
                      if (days === 1) return "yesterday"
                      return days + "d ago"
                    }
                  }
                  StatCell {
                    width: (parent.width - Style.space(18)) / 4
                    label: "BODYWEIGHT"
                    value: root.body && root.body.weight_kg
                      ? Model.weightLabel(root.body.weight_kg, root.unit)
                      : "—"
                  }
                  StatCell {
                    width: (parent.width - Style.space(18)) / 4
                    label: "WORKOUTS"
                    value: snapshot ? Model.numberLabel(snapshot.total_workouts) : "—"
                  }
                }
              }

              Column {
                id: rightColumn
                width: parent.width - leftColumn.width - parent.spacing
                spacing: Style.space(12)

                // 12-week volume
                Rectangle {
                  width: parent.width
                  height: Style.space(176)
                  radius: Math.max(6, Style.cornerRadius)
                  color: root.cardBg

                  Item {
                    anchors.fill: parent
                    anchors.margins: Style.space(14)

                    Item {
                      width: parent.width
                      height: Style.space(14)

                      Text {
                        anchors.left: parent.left
                        text: "12-WEEK VOLUME"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1.3
                      }
                      Text {
                        anchors.right: parent.right
                        text: "AVG " + Model.volumeShort(root.totals ? root.totals.avg_week_volume_kg : 0, root.unit)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Row {
                      id: barChart
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(30)
                      height: Style.space(88)
                      spacing: Style.space(4)

                      Repeater {
                        model: root.history

                        Item {
                          id: historyBar
                          required property var modelData
                          required property int index
                          width: (barChart.width - Style.space(4) * 11) / 12
                          height: barChart.height

                          Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            width: Math.max(3, parent.width * 0.7)
                            height: {
                              var values = root.history.map(function(row) { return row.volume_kg })
                              var peak = Math.max.apply(null, values.concat([1]))
                              return Math.max(Style.space(2),
                                Math.round((historyBar.modelData.volume_kg / peak) * (barChart.height - Style.space(8))))
                            }
                            radius: Style.space(2)
                            color: historyBar.index === root.history.length - 1 ? root.hevySky : root.hevyBlue
                            opacity: historyBar.index === root.history.length - 1 ? 1 : 0.5
                          }
                        }
                      }
                    }

                    Item {
                      id: monthRow
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: barChart.bottom
                      anchors.topMargin: Style.space(4)
                      height: Style.space(14)

                      Repeater {
                        model: root.history

                        Item {
                          id: monthCell
                          required property var modelData
                          required property int index
                          x: monthCell.index * (monthRow.width - Style.space(4) * 11) / 12
                            + monthCell.index * Style.space(4)
                          width: (monthRow.width - Style.space(4) * 11) / 12

                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: {
                              if (monthCell.index === 0) return true
                              var previous = root.history[monthCell.index - 1]
                              return !previous || Model.monthLabel(previous.start) !== Model.monthLabel(monthCell.modelData.start)
                            }
                            text: Model.monthLabel(monthCell.modelData.start)
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }

                    Item {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      height: Style.space(14)

                      Text {
                        anchors.left: parent.left
                        text: (root.totals && root.totals.best_week && root.totals.best_week.volume_kg > 0)
                          ? "BEST WEEK " + Model.volumeShort(root.totals.best_week.volume_kg, root.unit)
                            + " · " + Model.dateLabel(root.totals.best_week.start + "T12:00:00")
                          : ""
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        anchors.right: parent.right
                        text: (snapshot ? snapshot.total_workouts : 0) + " WORKOUTS LOGGED"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 0.6
                      }
                    }
                  }
                }

                // Muscle balance
                Rectangle {
                  width: parent.width
                  height: muscleColumn.implicitHeight + Style.space(28)
                  radius: Math.max(6, Style.cornerRadius)
                  color: root.cardBg

                  Column {
                    id: muscleColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(4)

                    Item {
                      width: parent.width
                      height: Style.space(14)

                      Text {
                        anchors.left: parent.left
                        text: "MUSCLE BALANCE"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1.3
                      }
                      Text {
                        anchors.right: parent.right
                        text: "LAST 30 DAYS"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 0.6
                      }
                    }

                    Repeater {
                      model: root.muscles.slice(0, 6)

                      Item {
                        id: muscleRow
                        required property var modelData
                        required property int index
                        width: parent.width
                        height: Style.space(16)

                        Text {
                          anchors.left: parent.left
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(64)
                          text: muscleRow.modelData.label
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Rectangle {
                          anchors.left: parent.left
                          anchors.leftMargin: Style.space(68)
                          anchors.right: musclePct.left
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          height: Style.space(5)
                          radius: height / 2
                          color: root.track

                          Rectangle {
                            width: parent.width * (muscleRow.modelData.pct / 100)
                            height: parent.height
                            radius: height / 2
                            color: root.muscleColors[muscleRow.index % root.muscleColors.length]
                          }
                        }

                        Text {
                          id: musclePct
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(36)
                          horizontalAlignment: Text.AlignRight
                          text: Model.percentLabel(muscleRow.modelData.pct)
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    Text {
                      visible: root.muscles.length === 0
                      text: "Log a few weighted sessions to see this."
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                // Top lifts
                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: Style.space(14)

                    Text {
                      anchors.left: parent.left
                      text: "TOP LIFTS"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1.3
                    }
                    Text {
                      anchors.right: parent.right
                      text: "BEST e1RM · 16 WEEKS"
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 0.6
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: recordsColumn.implicitHeight + Style.space(2)
                    radius: Math.max(6, Style.cornerRadius)
                    color: root.cardBg

                    Column {
                      id: recordsColumn
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter

                      Repeater {
                        model: root.records

                        Item {
                          id: recordRow
                          required property var modelData
                          required property int index
                          width: recordsColumn.width
                          height: Style.space(32)

                          Rectangle {
                            visible: recordRow.index > 0
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            height: Style.spacing.hairline
                            color: root.line
                          }

                          Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            text: "★"
                            color: root.hevyAmber
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(24)
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * 0.5
                            text: recordRow.modelData.title
                            color: root.barForeground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }

                          Text {
                            anchors.left: parent.left
                            anchors.leftMargin: parent.width * 0.52
                            anchors.verticalCenter: parent.verticalCenter
                            text: Model.weightLabel(recordRow.modelData.weight_kg, root.unit)
                              + " × " + recordRow.modelData.reps
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          Text {
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            text: Model.weightLabel(recordRow.modelData.e1rm_kg, root.unit)
                            color: root.hevyAmber
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                          }
                        }
                      }
                    }
                  }
                }

                Row {
                  width: parent.width

                  StatCell {
                    width: parent.width / 3
                    label: "LIFTED"
                    value: root.totals ? Model.volumeShort(root.totals.volume_kg, root.unit) : "—"
                  }
                  StatCell {
                    width: parent.width / 3
                    label: "SETS"
                    value: root.totals ? Model.numberLabel(root.totals.sets) : "—"
                  }
                  StatCell {
                    width: parent.width / 3
                    label: "AVG WEEK"
                    value: (Math.round(root.avgSessions * 10) / 10) + " sessions"
                  }
                }
              }
            }

            // ---------------------------------------------- extra tabs
            Flickable {
              id: deepScroller
              visible: root.authenticated && !root.showConnect && root.tab !== "overview"
              anchors.fill: parent
              contentWidth: width
              contentHeight: deepColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick

              Column {
                id: deepColumn
                width: deepScroller.width - Style.space(10)
                spacing: Style.space(12)

                Text {
                  visible: root.deep === null
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(60)
                  wrapMode: Text.Wrap
                  text: root.snapshot && root.snapshot.deep && root.snapshot.deep.error
                    ? "The extra analysis failed: " + Model.truncate(root.snapshot.deep.error, 160)
                    : "Refresh (⟳) to load progression, patterns and history."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                // ============================== PROGRESS
                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "progress" && root.dd.insights.length > 0
                  title: "WHAT YOUR DATA SAYS"
                  hint: root.dd.sessions_in_window + " sessions · last " + root.dd.window_weeks + " weeks"

                  Column {
                    width: parent.width
                    spacing: Style.space(8)

                    Repeater {
                      model: root.dd.insights

                      Rectangle {
                        id: tipCard
                        required property var modelData
                        width: parent.width
                        height: tipColumn.implicitHeight + Style.space(18)
                        radius: Style.space(6)
                        color: Util.alpha(root.barForeground, 0.04)

                        Rectangle {
                          x: Style.space(8)
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(3)
                          height: parent.height - Style.space(14)
                          radius: width / 2
                          color: tipCard.modelData.tone === "good" ? root.hevyGreen : tipCard.modelData.tone === "bad" ? root.hevyRose : root.faint
                        }
                        Column {
                          id: tipColumn
                          x: Style.space(22)
                          y: Style.space(9)
                          width: parent.width - Style.space(34)
                          spacing: Style.space(2)
                          Text {
                            width: parent.width
                            text: tipCard.modelData.title
                            color: root.barForeground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            font.bold: true
                          }
                          Text {
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: tipCard.modelData.text
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "progress"
                  title: "LIFT PROGRESSION"
                  hint: "estimated 1RM · your most repeated lifts"

                  Column {
                    width: parent.width

                    Text {
                      visible: root.dd.progression.length === 0
                      text: "Repeat a lift in two sessions and its trend shows up here."
                      color: root.faint
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Repeater {
                      model: root.dd.progression

                      Item {
                        id: liftRow
                        required property var modelData
                        required property int index
                        width: parent.width
                        height: Style.space(36)
                        readonly property string tone: Model.changeTone(modelData.change_pct)
                        readonly property color toneColor: tone === "up" ? root.hevyGreen : tone === "down" ? root.hevyRose : root.hevySky

                        Rectangle {
                          visible: liftRow.index > 0
                          width: parent.width
                          height: Style.spacing.hairline
                          color: root.line
                        }
                        Column {
                          x: 0
                          width: parent.width * 0.36
                          anchors.verticalCenter: parent.verticalCenter
                          Text {
                            width: parent.width
                            text: liftRow.modelData.title
                            color: root.barForeground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }
                          Text {
                            width: parent.width
                            text: liftRow.modelData.muscle + " · " + liftRow.modelData.sessions + " sessions"
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }
                        }
                        Spark {
                          x: parent.width * 0.40
                          width: parent.width * 0.24
                          height: Style.space(24)
                          anchors.verticalCenter: parent.verticalCenter
                          series: liftRow.modelData.series
                          color: liftRow.toneColor
                        }
                        Column {
                          x: parent.width * 0.68
                          width: parent.width * 0.18
                          anchors.verticalCenter: parent.verticalCenter
                          Text {
                            text: Model.setLabel(liftRow.modelData.last.weight_kg, liftRow.modelData.last.reps, root.unit)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                          Text {
                            text: "best " + Model.weightLabel(liftRow.modelData.best_e1rm_kg, root.unit)
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                        Text {
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          text: liftRow.modelData.change_pct === null ? "—" : Model.deltaLabel(liftRow.modelData.change_pct)
                          color: liftRow.toneColor
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "progress" && root.dd.prs.length > 0
                  title: "RECENT RECORDS"
                  hint: "each time a lift beat its own best"

                  Column {
                    width: parent.width

                    Repeater {
                      model: root.dd.prs

                      Item {
                        id: prRow
                        required property var modelData
                        required property int index
                        width: parent.width
                        height: Style.space(28)

                        Rectangle {
                          visible: prRow.index > 0
                          width: parent.width
                          height: Style.spacing.hairline
                          color: root.line
                        }
                        Text {
                          x: 0
                          anchors.verticalCenter: parent.verticalCenter
                          text: "★"
                          color: root.hevyAmber
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          x: Style.space(18)
                          width: parent.width * 0.4
                          anchors.verticalCenter: parent.verticalCenter
                          text: prRow.modelData.title
                          color: root.barForeground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                        }
                        Text {
                          x: parent.width * 0.46
                          anchors.verticalCenter: parent.verticalCenter
                          text: Model.setLabel(prRow.modelData.weight_kg, prRow.modelData.reps, root.unit)
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          x: parent.width * 0.64
                          anchors.verticalCenter: parent.verticalCenter
                          text: Model.weightLabel(prRow.modelData.previous_kg, root.unit) + " → " + Model.weightLabel(prRow.modelData.e1rm_kg, root.unit)
                          color: root.hevyAmber
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                        Text {
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          text: Model.shortDate(prRow.modelData.date)
                          color: root.faint
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                // ============================== PATTERNS
                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "patterns"
                  title: "WHEN YOU TRAIN"
                  hint: "sessions by weekday · last " + root.dd.window_weeks + " weeks"

                  Column {
                    width: parent.width
                    spacing: Style.space(14)

                    Row {
                      width: parent.width
                      height: Style.space(96)

                      Repeater {
                        model: root.dd.patterns.weekday

                        Item {
                          id: dayCol
                          required property var modelData
                          width: parent.width / 7
                          height: Style.space(96)
                          readonly property real share: Model.barShare(root.dd.patterns.weekday, "workouts", modelData.workouts)

                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: parent.height - Style.space(18) - dayBar.height - implicitHeight - Style.space(2)
                            text: dayCol.modelData.workouts
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                          Rectangle {
                            id: dayBar
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width * 0.5
                            height: Math.max(3, dayCol.share * (Style.space(96) - Style.space(40)))
                            y: parent.height - Style.space(18) - height
                            radius: Style.space(3)
                            color: root.hevySky
                            opacity: dayCol.modelData.workouts > 0 ? 0.9 : 0.25
                          }
                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: parent.height - implicitHeight
                            text: dayCol.modelData.label
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
                    }

                    Column {
                      width: parent.width
                      spacing: Style.space(2)

                      Repeater {
                        model: root.dd.patterns.time_of_day

                        HBar {
                          required property var modelData
                          width: parent.width
                          label: Model.timeLabel(modelData.key)
                          share: Model.barShare(root.dd.patterns.time_of_day, "workouts", modelData.workouts)
                          valueText: modelData.workouts + (modelData.workouts === 1 ? " session" : " sessions")
                          barColor: root.hevyViolet
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "patterns"
                  title: "WORKING SETS PER MUSCLE"
                  hint: "last 8 weeks · 10–20 a week is a common target"

                  Column {
                    id: heatGrid
                    width: parent.width
                    spacing: Style.space(3)
                    readonly property int weekCount: Math.max(1, root.dd.weekly_sets.weeks.length)
                    readonly property real cellW: (width - root.gridLabelW - root.gridAvgW) / weekCount

                    Row {
                      Item { width: root.gridLabelW; height: Style.space(14) }
                      Repeater {
                        model: root.dd.weekly_sets.weeks
                        Text {
                          required property string modelData
                          width: heatGrid.cellW
                          horizontalAlignment: Text.AlignHCenter
                          text: Model.shortDate(modelData).split(" ")[0] + " " + Model.shortDate(modelData).split(" ")[1]
                          color: root.faint
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption - 1
                        }
                      }
                      Text {
                        width: root.gridAvgW
                        horizontalAlignment: Text.AlignRight
                        text: "avg 4w"
                        color: root.faint
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Repeater {
                      model: root.dd.weekly_sets.rows

                      Row {
                        id: heatRow
                        required property var modelData
                        height: Style.space(26)

                        Text {
                          width: root.gridLabelW
                          height: parent.height
                          verticalAlignment: Text.AlignVCenter
                          text: heatRow.modelData.key.charAt(0).toUpperCase() + heatRow.modelData.key.slice(1)
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Repeater {
                          model: heatRow.modelData.weeks

                          Rectangle {
                            required property int modelData
                            width: heatGrid.cellW - 3
                            height: Style.space(23)
                            radius: Style.space(4)
                            color: Util.alpha(root.hevySky, Model.heatAlpha(modelData))

                            Text {
                              anchors.centerIn: parent
                              text: parent.modelData > 0 ? parent.modelData : "·"
                              color: parent.modelData >= 6 ? root.barForeground : root.faint
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }
                        }
                        Text {
                          width: root.gridAvgW
                          height: parent.height
                          verticalAlignment: Text.AlignVCenter
                          horizontalAlignment: Text.AlignRight
                          readonly property real avg: Model.recentAverage(heatRow.modelData.weeks)
                          text: (Math.round(avg * 10) / 10) + "/wk"
                          color: avg < 6 ? root.hevyRose : avg <= 20 ? root.hevyGreen : root.hevyAmber
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "patterns"
                  title: "PUSH · PULL · LEGS"
                  hint: "working sets, last " + (root.dd.balance.weeks || 4) + " weeks"

                  Column {
                    width: parent.width
                    spacing: Style.space(8)
                    readonly property real total: Math.max(1, (root.dd.balance.push || 0) + (root.dd.balance.pull || 0)
                      + (root.dd.balance.legs || 0) + (root.dd.balance.core || 0))

                    Row {
                      width: parent.width
                      height: Style.space(14)
                      spacing: 2
                      Repeater {
                        model: [
                          { key: "push", color: root.hevyBlue },
                          { key: "pull", color: root.hevyGreen },
                          { key: "legs", color: root.hevyAmber },
                          { key: "core", color: root.hevyViolet }
                        ]
                        Rectangle {
                          required property var modelData
                          width: Math.max(2, (parent.width - 6) * ((root.dd.balance[modelData.key] || 0) / parent.parent.total))
                          height: parent.height
                          radius: height / 2
                          color: modelData.color
                          visible: (root.dd.balance[modelData.key] || 0) > 0
                        }
                      }
                    }

                    Row {
                      spacing: Style.space(18)
                      Repeater {
                        model: [
                          { key: "push", label: "Push", color: root.hevyBlue },
                          { key: "pull", label: "Pull", color: root.hevyGreen },
                          { key: "legs", label: "Legs", color: root.hevyAmber },
                          { key: "core", label: "Core", color: root.hevyViolet }
                        ]
                        Row {
                          required property var modelData
                          spacing: Style.space(6)
                          Rectangle {
                            width: Style.space(9)
                            height: width
                            radius: width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: parent.modelData.color
                          }
                          Text {
                            text: parent.modelData.label + " " + (root.dd.balance[parent.modelData.key] || 0)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "patterns"
                  title: "HOW YOU TRAIN"
                  hint: "reps per set and session length"

                  Column {
                    width: parent.width
                    spacing: Style.space(12)

                    Column {
                      width: parent.width
                      spacing: Style.space(2)
                      Repeater {
                        model: root.dd.patterns.rep_ranges

                        HBar {
                          required property var modelData
                          width: parent.width
                          label: modelData.range + " reps"
                          share: Model.barShare(root.dd.patterns.rep_ranges, "sets", modelData.sets)
                          valueText: modelData.sets + " sets · " + Math.round(Model.sumOf(root.dd.patterns.rep_ranges, "sets") > 0
                            ? modelData.sets / Model.sumOf(root.dd.patterns.rep_ranges, "sets") * 100 : 0) + "%"
                          barColor: root.hevySky
                        }
                      }
                    }

                    Item {
                      id: lengthChart
                      width: parent.width
                      height: Style.space(86)
                      readonly property var weeks: root.dd.duration_weeks
                      readonly property real peak: Math.max(60, Model.sumOf([{ v: 0 }], "v"), (function() {
                        var m = 0
                        for (var i = 0; i < weeks.length; i++) m = Math.max(m, weeks[i].avg_min || 0)
                        return m
                      })())

                      Repeater {
                        model: lengthChart.weeks

                        Item {
                          id: lenCol
                          required property var modelData
                          required property int index
                          width: lengthChart.width / Math.max(1, lengthChart.weeks.length)
                          x: index * width
                          height: lengthChart.height

                          Rectangle {
                            visible: lenCol.modelData.avg_min !== null
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width * 0.6
                            height: Math.max(3, (lenCol.modelData.avg_min || 0) / lengthChart.peak * (lengthChart.height - Style.space(30)))
                            y: lengthChart.height - Style.space(14) - height
                            radius: Style.space(3)
                            color: root.hevyViolet
                            opacity: 0.85
                          }
                          Text {
                            visible: lenCol.modelData.avg_min !== null
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: lengthChart.height - Style.space(14) - Math.max(3, (lenCol.modelData.avg_min || 0) / lengthChart.peak * (lengthChart.height - Style.space(30))) - implicitHeight
                            text: lenCol.modelData.avg_min
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption - 1
                          }
                          Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: lengthChart.height - implicitHeight
                            text: (lenCol.index % 3 === 0 || lenCol.index === lengthChart.weeks.length - 1) ? Model.shortDate(lenCol.modelData.start) : ""
                            color: root.faint
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption - 1
                          }
                        }
                      }
                    }
                  }
                }

                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "patterns" && root.dd.averages.sessions > 0
                  title: "AVERAGES"
                  hint: root.dd.averages.sessions + " sessions over " + root.dd.averages.span_weeks + " weeks"

                  Row {
                    width: parent.width

                    StatCell { width: parent.width / 6; label: "PER WEEK"; value: String(root.dd.averages.per_week) }
                    StatCell { width: parent.width / 6; label: "SESSION"; value: root.dd.averages.duration_min ? root.dd.averages.duration_min + " min" : "—" }
                    StatCell { width: parent.width / 6; label: "SETS"; value: String(root.dd.averages.sets) }
                    StatCell { width: parent.width / 6; label: "VOLUME"; value: Model.volumeShort(root.dd.averages.volume_kg, root.unit) }
                    StatCell { width: parent.width / 6; label: "LONGEST GAP"; value: root.dd.averages.longest_gap_days + " d" }
                    StatCell { width: parent.width / 6; label: "SINCE LAST"; value: root.dd.averages.current_gap_days + " d" }
                  }
                }

                // ============================== HISTORY
                HSection {
                  width: parent.width
                  visible: root.deep !== null && root.tab === "history"
                  title: "RECENT SESSIONS"
                  hint: "your last " + root.dd.recent.length + " workouts"

                  Column {
                    width: parent.width
                    spacing: Style.space(10)

                    Repeater {
                      model: root.dd.recent

                      Rectangle {
                        id: sessionCard
                        required property var modelData
                        width: parent.width
                        height: sessionColumn.implicitHeight + Style.space(18)
                        radius: Style.space(6)
                        color: Util.alpha(root.barForeground, 0.04)

                        Column {
                          id: sessionColumn
                          x: Style.space(12)
                          y: Style.space(9)
                          width: parent.width - Style.space(24)
                          spacing: Style.space(4)

                          Item {
                            width: parent.width
                            height: Style.space(20)

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              text: sessionCard.modelData.title
                              color: root.barForeground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                              font.bold: true
                            }
                            Text {
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              text: Model.dateLabel(sessionCard.modelData.start) + "  ·  " + Model.durationLabel(sessionCard.modelData.duration_s)
                                + "  ·  " + Model.volumeShort(sessionCard.modelData.volume_kg, root.unit) + "  ·  " + sessionCard.modelData.sets + " sets"
                              color: root.dim
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }

                          Repeater {
                            model: sessionCard.modelData.exercises

                            Item {
                              id: exRow
                              required property var modelData
                              width: parent.width
                              height: Style.space(18)

                              Text {
                                width: parent.width * 0.6
                                anchors.verticalCenter: parent.verticalCenter
                                text: exRow.modelData.title
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                              }
                              Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: exRow.modelData.sets + " sets" + (exRow.modelData.top ? "  ·  best " + Model.setLabel(exRow.modelData.top.weight_kg, exRow.modelData.top.reps, root.unit) : "")
                                color: root.faint
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }

                Item { width: 1; height: Style.space(4) }
              }
            }
          }

          // ------------------------------------------------------- footer
          Item {
            id: footer
            width: parent.width
            height: Style.space(24)
            visible: root.authenticated && !root.showConnect

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.isDemo
                  ? "Preview only — connect to see your data."
                  : ("Last " + Model.relativeUpdated(snapshot ? snapshot.fetched_at : 0, root.nowSeconds)
                    + (root.stale ? " · showing cached data" : ""))
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.isDemo
                text: "Connect"
                foreground: root.hevySky
                accent: root.hevySky
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(3)
                onClicked: {
                  root.connectRequested = true
                  root.snapshot = null
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.isDemo
                iconText: ""
                tooltipText: "Disconnect Hevy"
                foreground: root.dim
                accent: root.hevyRose
                fontFamily: root.fontFamily
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(3)
                onClicked: root.askDisconnect()
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "DATA BY"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.5
              }

              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(24)
                height: Style.space(21)
                source: "hevy-mark-white.svg"
                fillMode: Image.PreserveAspectFit
                opacity: 0.72
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
              }
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        z: 30
        opened: root.confirmDisconnect
        message: "Disconnect Hevy? This deletes the local API key and cached dashboard. Your Hevy account is not touched."
        confirmText: "Disconnect"
        background: Color.popups.background
        foreground: root.barForeground
        fontFamily: root.fontFamily
        onCanceled: root.confirmDisconnect = false
        onConfirmed: root.disconnect()
      }
    }
  }

  // ------------------------------------------------------------- components

  component HSection: Rectangle {
    id: sec
    property string title: ""
    property string hint: ""
    default property alias content: slot.data

    height: slot.height + Style.space(46)
    radius: Math.max(6, Style.cornerRadius)
    color: root.cardBg

    Text {
      x: Style.space(14)
      y: Style.space(11)
      text: sec.title
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.3
    }
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      y: Style.space(11)
      text: sec.hint
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 0.6
    }
    Item {
      id: slot
      x: Style.space(14)
      y: Style.space(32)
      width: sec.width - Style.space(28)
      height: childrenRect.height
    }
  }

  component Spark: Item {
    id: spark
    property var series: []
    property color color: root.hevySky
    readonly property var pts: Model.sparkline(series, width, height)

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: Style.space(1.8)
        strokeColor: spark.color
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline {
          path: spark.pts.map(function(p) { return Qt.point(p.x, p.y) })
        }
      }
    }
    Rectangle {
      visible: spark.pts.length > 0
      x: spark.pts.length ? spark.pts[spark.pts.length - 1].x - width / 2 : 0
      y: spark.pts.length ? spark.pts[spark.pts.length - 1].y - height / 2 : 0
      width: Style.space(6)
      height: width
      radius: width / 2
      color: spark.color
    }
  }

  component HBar: Item {
    id: hb
    property string label: ""
    property real share: 0
    property string valueText: ""
    property color barColor: root.hevySky
    property real labelWidth: Style.space(84)
    property real valueWidth: Style.space(104)
    height: Style.space(22)

    Text {
      width: hb.labelWidth
      anchors.verticalCenter: parent.verticalCenter
      text: hb.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Rectangle {
      x: hb.labelWidth
      width: hb.width - hb.labelWidth - hb.valueWidth
      height: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      radius: height / 2
      color: root.track

      Rectangle {
        width: hb.share > 0 ? Math.max(height, parent.width * hb.share) : 0
        height: parent.height
        radius: height / 2
        color: hb.barColor
      }
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: hb.valueText
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component TargetRing: Item {
    id: ring
    property int done: 0
    property int target: 4
    readonly property real fraction: target > 0 ? Math.max(0, Math.min(1, done / target)) : 0
    readonly property real diameter: Style.space(78)
    readonly property real arcWidth: Style.space(6)
    readonly property real arcRadius: diameter / 2 - arcWidth

    width: diameter
    height: diameter

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: ring.arcWidth
        strokeColor: root.track
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2
          centerY: ring.height / 2
          radiusX: ring.arcRadius
          radiusY: ring.arcRadius
          startAngle: -90
          sweepAngle: 359.9
        }
      }

      ShapePath {
        strokeWidth: ring.arcWidth
        strokeColor: root.hevyBlue
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.width / 2
          centerY: ring.height / 2
          radiusX: ring.arcRadius
          radiusY: ring.arcRadius
          startAngle: -90
          sweepAngle: 359.9 * ring.fraction
        }
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: -2

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: ring.done + "/" + ring.target
        color: root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "WEEK"
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.8
      }
    }
  }

  component StatCell: Column {
    id: cell
    property string label: ""
    property string value: ""
    spacing: Style.space(2)

    Text {
      text: cell.label
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      text: cell.value
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }
}

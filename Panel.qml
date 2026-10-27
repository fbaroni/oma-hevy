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
    target: "dev.fede.oma-hevy"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function demo(): void { root.previewDemo(); root.open() }
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
      width: Math.min(parent.width - Style.space(72), Style.space(1000))
      height: Math.min(parent.height - Style.space(72), Style.space(800))
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

          // --------------------------------------------------------- body
          Item {
            id: body
            width: parent.width
            height: cardColumn.height - header.height - footer.height - Style.spacing.hairline
              - cardColumn.spacing * 3

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
              visible: root.authenticated && !root.showConnect
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

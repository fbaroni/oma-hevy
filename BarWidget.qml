import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "fbaroni.oma-hevy"

  // `"hidden": true` in this widget's shell.json entry removes the button from
  // the bar. The widget stays loaded, so the panel still opens from the Omarchy
  // menu / app launcher or over IPC.
  readonly property bool hiddenInBar: !!(root.settings && root.settings.hidden === true)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The bar carries one glanceable number: volume lifted this week. The "H"
  // keeps the Hevy mark without needing the logo image inside the bar's text
  // label, which only paints plain text.
  WidgetButton {
    id: button
    bar: root.bar
    text: root.hiddenInBar ? "" : "H " + (panelLoader.item ? panelLoader.item.barLabel : "—")
    horizontalMargin: 6
    verticalPadding: 6
    fixedHeight: root.barSize
    active: panelLoader.item ? panelLoader.item.authenticated : false
    activeColor: "#5AB4FF"
    tooltipText: {
      if (!panelLoader.item || !panelLoader.item.authenticated) return "Hevy — click to connect"
      var snap = panelLoader.item.snapshot
      if (!snap || !snap.week) return "Hevy"
      return "Hevy · " + snap.week.workouts + "/" + snap.week.target + " sessions · "
        + panelLoader.item.barLabel + " this week"
    }
    onPressed: function(btn) {
      if (btn === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}

import QtQuick
import Quickshell
import qs.Ui

// LocalWrap bar widget for the Omarchy Quattro bar.
//
// This is the manifest entry point. It shows a compact ready/total summary
// and forwards the panel lifecycle contract (open/close/toggle and the
// popout-switch hooks) to the cockpit loaded from Panel.qml. The loader is
// always active so the panel — which owns manifest state and any processes
// the user explicitly started — persists while the widget is in the bar.
BarWidget {
  id: root
  moduleName: "io.github.tcballard.localwrap"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.barText : "LW"
    tooltipText: panelLoader.item
      ? panelLoader.item.barTooltip
      : "Open LocalWrap"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}

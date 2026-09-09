import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Fingerprint reader status & control (fingerprint-ocv / FPC 9201).
// Bar: colorized fingerprint glyph (state color) + enrolled count.
// Popup (actions + driver control first, so nothing hides behind a fold):
//   1. Actions: Verify / Register / Delete-all
//   2. Driver: start|restart|stop toggle + liveness
//   3. Status: sensor, fingerprints count, registered list
Panel {
  id: root
  moduleName: "zimixin.fingerprint"
  ipcTarget: "zimixin.fingerprint"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string collector:
    home + "/.config/omarchy/plugins/zimixin.fingerprint/bin/fp-status.sh"
  readonly property string action:
    home + "/.config/omarchy/plugins/zimixin.fingerprint/bin/fp-action.py"
  readonly property string statusFile:
    (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/fingerprint/status.json"
  readonly property string driverUnit: "fingerprint-ocv.service"

  // ---- live state (fed from status.json)
  property bool ready: false
  property bool enrolled: false
  property bool fingerPresent: false
  property bool daemonUp: false
  property bool stale: false
  property bool driverBusy: false
  property int  fingerCount: 0
  property var  names: []
  property double nowMs: Date.now()
  property double updatedMs: 0

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function iconSource() { return Qt.resolvedUrl("assets/fingerprint.svg") }

  // fingerprint daemon has NO finger-up event: `finger-present` latches true
  // after the first touch of a scan and never clears, so it is NOT a live
  // "finger down now" reading. Therefore state is driven only by enrolled /
  // daemon-up, never by fingerPresent.
  readonly property color stateColor:
    !root.ready ? root.dim
    : !root.daemonUp ? root.urgent
    : root.enrolled ? root.foreground
    : root.urgent

  readonly property string stateLabel:
    !root.ready ? "Драйвер не отвечает"
    : !root.daemonUp ? "Драйвер не запущен"
    : root.enrolled ? "Готов к проверке"
    : "Отпечаток не записан"

  FileView {
    id: statusView
    path: root.statusFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
    onLoadFailed: root.ready = false
  }

  Process {
    id: collectProc
    running: false
    command: root.collector.length > 0 ? [root.collector] : []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  // No background auto-poll (fingerprint-ocv can abort on concurrent D-Bus).
  function refresh() {
    if (!collectProc.running) collectProc.running = true
  }

  function apply(content) {
    var data = null
    try { data = JSON.parse(String(content || "")) } catch (e) { data = null }
    root.ready = data ? (data.ready === true) : false
    if (!root.ready) return
    root.enrolled      = data.enrolled === true
    root.fingerCount   = Number(data.count) || Number(data.finger_count) || 0
    root.fingerPresent = data.finger_present === true
    root.daemonUp      = data.daemon_up === true
    root.stale         = data.stale === true
    root.names         = Array.isArray(data.names) ? data.names : []
    var g = Number(data.generated_at) || 0
    root.updatedMs     = g > 0 ? g * 1000 : root.nowMs
    root.nowMs         = Date.now()
  }

  function fmtCompact() {
    if (!root.ready) return ""
    return root.enrolled ? String(root.fingerCount) : ""
  }

  function open()  { root.controller.show(); root.refresh() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  function updatedText() {
    if (!root.ready) return ""
    var mins = Math.max(0, Math.round((root.nowMs - root.updatedMs) / 60000))
    return (mins === 0 ? "только что" : mins + " мин назад") + (root.stale ? " · устарело" : "")
  }

  function humanName(n) {
    var s = String(n || "")
    if (s === "primary") return "Основной отпечаток"
    return s
  }

  function runAction(which) {
    root.close()
    if (root.bar) {
      var arg = (which === "enroll" || which === "verify") ? " '" + which + "'" : " " + which
      root.bar.run('omarchy-launch-floating-terminal-with-presentation "' + root.action + arg + '"')
    }
  }

  // Driver control (systemd --user). Runs start|stop, then refreshes status.
  function runDriver(cmd) {
    if (root.driverBusy || !root.bar) return
    root.driverBusy = true
    var job = "systemctl --user " + cmd + " " + root.driverUnit
    root.bar.run('sh -c "' + job + ' & sleep 1; ' + root.collector + '"')
    Qt.callLater(1500, function() { root.driverBusy = false })
  }

  function driverAction() {
    if (root.driverBusy) return
    if (root.daemonUp) root.runDriver("restart")
    else root.runDriver("start")
  }

  // ---------------------------------------------------------------- bar button
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱂉"
    labelVisible: false
    hasVisualContent: true
    fixedWidth: button.vertical ? Style.bar.iconSlot : (barRow.implicitWidth + Style.space(16))
    fixedHeight: button.vertical ? Style.bar.iconSlot : -1
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: barRow
      visible: !button.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        Image {
          id: barMark
          anchors.fill: parent
          source: root.iconSource()
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: barMark
          source: barMark
          visible: barMark.status === Image.Ready
          colorization: 1.0
          colorizationColor: root.stateColor
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: barMark.status !== Image.Ready
          text: button.text
          color: root.stateColor
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.fmtCompact() !== ""
        text: root.fmtCompact()
        color: root.stateColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // ---------------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.refresh()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        if (t === "v" || t === "V") root.runAction("verify")
        if (t === "e" || t === "E") root.runAction("enroll")
        if (t === "d" || t === "D") root.runAction("delete")
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        // ---- Hero ----
        PanelHero {
          id: hero
          width: parent.width
          title: "Отпечаток пальца"
          meta: root.ready ? root.stateLabel
            : (root.driverBusy ? "перезапуск драйвера…" : "Драйвер не отвечает")
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Item {
              width: Style.font.display
              height: Style.font.display
              Image {
                id: heroMarkImage
                anchors.fill: parent
                source: root.iconSource()
                sourceSize.width: Style.font.display * 2
                sourceSize.height: Style.font.display * 2
                fillMode: Image.PreserveAspectFit
                visible: false
                layer.enabled: true
              }
              MultiEffect {
                anchors.fill: heroMarkImage
                source: heroMarkImage
                visible: heroMarkImage.status === Image.Ready
                colorization: 1.0
                colorizationColor: root.stateColor
              }
            }
          }

          trailingControl: Component {
            Column {
              spacing: Style.space(2)
              width: Math.max(countVal.implicitWidth, countCap.implicitWidth)

              Text {
                textFormat: Text.PlainText
                id: countVal
                width: parent.width
                text: root.enrolled ? String(root.fingerCount) : "—"
                color: root.enrolled ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                horizontalAlignment: Text.AlignRight
              }
              Text {
                textFormat: Text.PlainText
                id: countCap
                width: parent.width
                text: "ОТПЕЧАТКИ"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                horizontalAlignment: Text.AlignRight
              }
            }
          }
        }

        // ---- Actions (first, always visible) ----
        PanelSectionHeader {
          width: parent.width
          text: "ДЕЙСТВИЯ"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Grid {
          id: gridActions
          width: parent.width
          columns: 2
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(8)

          ActionButton {
            width: (gridActions.width - gridActions.columnSpacing) / 2
            text: "Зарегистрировать"
            sub: "записать отпечаток"
            run: "enroll"
          }
          ActionButton {
            width: (gridActions.width - gridActions.columnSpacing) / 2
            text: "Проверить"
            sub: "сверка с любым"
            run: "verify"
            enabled: root.enrolled
          }
          ActionButton {
            width: (gridActions.width - gridActions.columnSpacing) / 2
            text: "Удалить все"
            sub: "стереть отпечатки"
            run: "delete"
            enabled: root.enrolled
            danger: true
          }
          ActionButton {
            width: (gridActions.width - gridActions.columnSpacing) / 2
            text: "Обновить"
            sub: "R / ПКМ"
            run: "_refresh"
          }
        }

        // ---- Driver ----
        PanelSectionHeader {
          width: parent.width
          text: "ДРАЙВЕР"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: driverRow
          width: parent.width
          spacing: Style.space(8)

          DriverTile {
            width: (driverRow.width - driverRow.spacing * 1) / 2
            active: root.daemonUp
            label: root.daemonUp ? "Запущен" : "Остановлен"
            sub: root.daemonUp ? "перезапустить" : "запустить"
          }

          Item {
            width: (driverRow.width - driverRow.spacing * 1) / 2
            implicitHeight: scannerInfo.implicitHeight + Style.space(8)

            Column {
              id: scannerInfo
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Сканер"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "press · 10 стадий"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        // ---- Register hint (only when nothing recorded) ----
        Text {
          visible: root.ready && !root.enrolled && root.daemonUp
          width: parent.width
          text: "Зарегистрируй палец: 10 касаний, ~1с держать, пауза ~2с."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---- Registered prints ----
        Column {
          visible: root.names.length > 0
          width: parent.width
          spacing: Style.spacing.sm

          PanelSectionHeader {
            width: parent.width
            text: "ЗАПИСАННЫЕ"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.names
            FingerRow { width: parent.width; name: modelData }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          textFormat: Text.PlainText
          visible: root.ready
          width: parent.width
          text: "обновлено " + root.updatedText()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "ЛКМ — панель · R — обновить · V/E/D — проверить/записать/удалить · Esc — закрыть"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------ components
  component FingerRow: Item {
    id: fingerRow
    property string name: ""

    implicitHeight: Math.max(fingerName.implicitHeight, Style.space(20))

    Text {
      textFormat: Text.PlainText
      text: "✓"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      id: fingerName
      text: root.humanName(fingerRow.name)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(20)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  // Full-width action button with hint line.
  component ActionButton: Item {
    id: actionButton
    property string text: ""
    property string sub: ""
    property string run: ""
    property bool danger: false
    property bool enabled: true

    implicitHeight: Style.space(38)

    Rectangle {
      anchors.fill: parent
      radius: Math.max(3, Style.cornerRadius - 3)
      color: root.alpha(root.foreground,
                        actionMa.containsMouse ? 0.14 : 0.06)
      border.width: 1
      border.color: root.alpha(actionButton.danger ? root.urgent : root.foreground,
                               actionMa.containsMouse ? 0.6 : 0.32)
      visible: actionButton.enabled
    }

    Rectangle {
      anchors.fill: parent
      radius: Math.max(3, Style.cornerRadius - 3)
      color: root.alpha(root.foreground, 0.03)
      border.width: 1
      border.color: root.alpha(root.dim, 0.35)
      visible: !actionButton.enabled
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: actionButton.text
        color: actionButton.enabled
          ? (actionButton.danger ? root.urgent : root.foreground)
          : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: !actionButton.danger
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: actionButton.sub
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: actionMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionButton.enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
      acceptedButtons: Qt.LeftButton
      onClicked: {
        if (!actionButton.enabled) return
        if (actionButton.run === "_refresh") root.refresh()
        else root.runAction(actionButton.run)
      }
    }
  }

  // Driver start/restart/stop control.
  component DriverTile: Item {
    id: driverTile
    property bool active: false
    property string label: ""
    property string sub: ""

    implicitHeight: Style.space(38)

    Rectangle {
      anchors.fill: parent
      radius: Math.max(3, Style.cornerRadius - 3)
      color: root.alpha(driverTile.active ? root.accent : root.urgent,
                        driverMa.containsMouse ? 0.16 : 0.07)
      border.width: 1
      border.color: root.alpha(driverTile.active ? root.accent : root.urgent,
                               driverMa.containsMouse ? 0.6 : 0.32)
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: (driverTile.active ? "●  " : "○  ") + driverTile.label
        color: driverTile.active ? root.accent : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: driverTile.sub
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: driverMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton
      onClicked: root.driverAction()
    }
  }
}
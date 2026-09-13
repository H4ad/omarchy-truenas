import QtQuick
import qs.Commons
import qs.Ui

// The confirmation a destructive write goes through.
//
// It is the shell's ConfirmDialog with a safe default and one entry point, so a
// destructive action can never be armed with the confirm button already under
// the pointer: `arm()` always selects Cancel, and the panel's key catcher
// moves the selection only when the user asks it to.
//
// It must be declared inside the PanelKeyCatcher and never at Panel.qml's root
// scope. BarWidget.qml loads that root object into a `Loader { visible: false }`
// and the panel you can see is a separate layer-shell window, so a visual child
// up there renders nowhere at all.
//
//   ConfirmAction {
//     id: confirmAction
//     foreground: root.contentForeground
//     fontFamily: root.contentFontFamily
//     onConfirmed: { ... }
//     onCanceled: { confirmAction.opened = false }
//   }
ConfirmDialog {
  id: root

  // Index 0 is Cancel. Arming something destructive must not pre-select the
  // destructive half.
  selectedIndex: 0
  confirmText: "Run"
  cancelText: "Cancel"

  function arm(message, label) {
    root.message = String(message || "")
    if (label !== undefined && label !== null && String(label) !== "")
      root.confirmText = String(label)
    root.selectedIndex = 0
    root.opened = true
  }
}

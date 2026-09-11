pragma Singleton
import QtQuick
QtObject {
 property real fontScale: 1
 property int cornerRadius: 8
 property var font: ({body:16,caption:13,display:28})
 function space(n) { return Math.max(1, Math.round(n * fontScale)) }
}

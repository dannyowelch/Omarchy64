import QtQuick
import qs.Commons

// Chunky PETSCII-style "64" lockup. Single-color so it tracks the bar
// foreground like the other plugin glyphs.
Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property int cols: 16
  readonly property int rows: 16
  readonly property real px: iconSize / cols
  readonly property var bits: [
    "................",
    "................",
    "................",
    ".######.#.....#.",
    ".######.#.....#.",
    ".#......#.....#.",
    ".#......#.....#.",
    ".######.#######.",
    ".######.#######.",
    ".#....#.......#.",
    ".#....#.......#.",
    ".######.......#.",
    ".######.......#.",
    "................",
    "................",
    "................"
  ]
  readonly property var lit: {
    var out = []
    for (var r = 0; r < root.rows; r++) {
      var row = root.bits[r]
      for (var c = 0; c < root.cols; c++) {
        if (row.charAt(c) === "#")
          out.push(r * root.cols + c)
      }
    }
    return out
  }

  Repeater {
    model: root.lit
    Rectangle {
      required property int modelData
      x: (modelData % root.cols) * root.px
      y: Math.floor(modelData / root.cols) * root.px
      width: root.px
      height: root.px
      color: root.color
    }
  }
}

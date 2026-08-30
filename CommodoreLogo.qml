import QtQuick
import QtQuick.Shapes

// Four-band Commodore "duck lips" C. Concentric elliptical rings with a
// bite on the right so the silhouette reads as lips / a duck bill, even
// at bar-icon size.
Item {
  id: root

  property real iconSize: 16
  property bool rainbow: true
  property color color: "#e31c23"
  property real opening: 38

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property color band0: rainbow ? "#e31c23" : color
  readonly property color band1: rainbow ? "#f77f00" : color
  readonly property color band2: rainbow ? "#ffd100" : color
  readonly property color band3: rainbow ? "#2bb24c" : color

  readonly property real cx: width * 0.45
  readonly property real cy: height * 0.50
  readonly property real maxRx: width * 0.50
  readonly property real maxRy: height * 0.40
  readonly property real startAngle: opening
  readonly property real sweep: 360 - opening * 2
  readonly property real startRad: startAngle * Math.PI / 180

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    Stripe { outerFrac: 1.00; innerFrac: 0.79; stripeColor: root.band0 }
    Stripe { outerFrac: 0.79; innerFrac: 0.58; stripeColor: root.band1 }
    Stripe { outerFrac: 0.58; innerFrac: 0.37; stripeColor: root.band2 }
    Stripe { outerFrac: 0.37; innerFrac: 0.16; stripeColor: root.band3 }
  }

  component Stripe: ShapePath {
    id: stripe
    property real outerFrac: 1
    property real innerFrac: 0.78
    property color stripeColor: "#e31c23"
    readonly property real ox: root.maxRx * outerFrac
    readonly property real oy: root.maxRy * outerFrac
    readonly property real ix: root.maxRx * innerFrac
    readonly property real iy: root.maxRy * innerFrac

    fillColor: stripeColor
    strokeWidth: 0
    capStyle: ShapePath.FlatCap
    joinStyle: ShapePath.MiterJoin
    startX: root.cx + ox * Math.cos(root.startRad)
    startY: root.cy + oy * Math.sin(root.startRad)

    PathAngleArc {
      centerX: root.cx
      centerY: root.cy
      radiusX: stripe.ox
      radiusY: stripe.oy
      startAngle: root.startAngle
      sweepAngle: root.sweep
    }
    PathAngleArc {
      centerX: root.cx
      centerY: root.cy
      radiusX: stripe.ix
      radiusY: stripe.iy
      startAngle: root.startAngle + root.sweep
      sweepAngle: -root.sweep
    }
  }
}

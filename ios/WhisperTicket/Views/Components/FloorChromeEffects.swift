import SwiftUI

// MARK: - Zoom navigation transition (iOS 18+, graceful fallback on 17)

/// The floor map's signature moment: tapping a table zooms the actual tile into
/// the destination screen while the floor falls away. Uses the system zoom
/// navigation transition on iOS 18+; iOS 17 gets the standard push.
extension View {
    @ViewBuilder
    func tableZoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func tableZoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

// MARK: - Pressed-state scale for tappable floor tiles

/// Quiet tactile feedback: tiles compress slightly under the finger.
struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Walls layer

/// Renders floor walls (open polylines in canvas coordinates) as chrome-outlined
/// strokes on the dark floor. Shared by the live map and the plan editor.
struct FloorWallsLayer: View {
    let walls: [FloorWall]
    var highlightedWallId: String? = nil

    var body: some View {
        Canvas { ctx, _ in
            for wall in walls {
                guard wall.points.count >= 2 else { continue }
                var path = Path()
                path.move(to: wall.points[0])
                for pt in wall.points.dropFirst() { path.addLine(to: pt) }

                let isHighlighted = wall.id == highlightedWallId
                let edge: Color = isHighlighted ? .chromeRed : Color.chromeSilverHigh.opacity(0.55)
                // Outer stroke = wall edge, inner dark stroke = wall body,
                // giving an outlined architectural look on the dark canvas.
                ctx.stroke(path, with: .color(edge), style: StrokeStyle(
                    lineWidth: wall.thickness, lineCap: .round, lineJoin: .round
                ))
                ctx.stroke(path, with: .color(Color.chromeBackground.opacity(0.92)), style: StrokeStyle(
                    lineWidth: max(1, wall.thickness - 4), lineCap: .round, lineJoin: .round
                ))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dashed in-progress wall while the user is placing points in the editor.
struct WallDraftLayer: View {
    let points: [CGPoint]

    var body: some View {
        Canvas { ctx, _ in
            guard let first = points.first else { return }
            if points.count >= 2 {
                var path = Path()
                path.move(to: first)
                for pt in points.dropFirst() { path.addLine(to: pt) }
                ctx.stroke(path, with: .color(Color.chromePrimary.opacity(0.9)), style: StrokeStyle(
                    lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [7, 5]
                ))
            }
            for pt in points {
                let dot = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: dot), with: .color(Color.chromePrimary))
                ctx.stroke(Path(ellipseIn: dot.insetBy(dx: -2.5, dy: -2.5)),
                           with: .color(Color.chromePrimary.opacity(0.4)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

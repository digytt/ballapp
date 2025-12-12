import SwiftUI
internal import Combine

// MARK: - Size reading helpers for measuring the controls overlay (file-scoped)
private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func readHeight(onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}

private struct SimBall: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
}

struct ContentView: View {
    @State private var balls: [SimBall] = []
    @State private var initialVelocity: CGVector = CGVector(dx: 3, dy: 4)
    private let defaultBallSize: CGFloat = 40
    @State private var ballSize: CGFloat = 40
    @State private var isRunning: Bool = true
    @State private var ballColor: Color = .blue
    @State private var isRainbowMode: Bool = false
    @State private var rainbowHue: Double = 0.0
    @State private var isGravityEnabled: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragStartPosition: CGPoint = .zero
    @State private var speedMultiplier: CGFloat = 1.0
    @State private var controlsHeight: CGFloat = 0
    
    @State private var draggingBallIndex: Int? = nil

    @State private var lastDragTime: Date? = nil
    @State private var lastDragLocation: CGPoint = .zero
    @State private var recentVelocities: [CGVector] = [] // small buffer of instantaneous velocities

    @State private var ballCount: Int = 1
    @State private var ballCountText: String = "1"

    // Physics constants
    private let gravity: CGFloat = 980.0 / 60.0 / 60.0 // ~980 px/s^2 scaled to px/frame^2 for 60 FPS
    private let airDrag: CGFloat = 0.995               // multiplicative drag per frame (close to 1.0)
    private let restitution: CGFloat = 0.75            // bounciness 0..1 (1 is perfectly elastic)
    private let groundFriction: CGFloat = 0.98         // horizontal energy loss when on floor/walls
    private let terminalSpeed: CGFloat = 1200.0 / 60.0 // clamp speed to avoid tunneling (px/frame)

    private func applyAirDrag(_ v: CGFloat) -> CGFloat {
        v * airDrag
    }

    private func clampMagnitude(_ v: CGVector, max m: CGFloat) -> CGVector {
        let mag = sqrt(v.dx * v.dx + v.dy * v.dy)
        guard mag > m && mag > 0 else { return v }
        let scale = m / mag
        return CGVector(dx: v.dx * scale, dy: v.dy * scale)
    }

    private func zeroIfSmall(_ v: CGFloat, threshold: CGFloat = 0.02) -> CGFloat { abs(v) < threshold ? 0 : v }

    private func clampBallCount(_ n: Int) -> Int { max(1, min(n, 50)) }

    private func reseedBalls(in size: CGSize) {
        let radius = ballSize / 2
        let minX = radius
        let maxX = max(minX, size.width - radius)
        let minY = radius
        let maxY = max(minY, size.height - radius - controlsHeight)
        balls = (0..<ballCount).map { i in
            let t = CGFloat(i) / CGFloat(max(1, ballCount - 1))
            let x = minX + t * (maxX - minX)
            let y = minY + (1 - t) * (maxY - minY)
            return SimBall(position: CGPoint(x: x, y: y), velocity: initialVelocity)
        }
    }

    private func resolveBallCollisions() {
        let r = ballSize / 2
        let restitution = isGravityEnabled ? self.restitution : 1.0
        let count = balls.count
        guard count > 1 else { return }

        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                // Skip the dragged ball to avoid fighting the user
                if let dragging = draggingBallIndex, (dragging == i || dragging == j) { continue }
                let pi = balls[i].position
                let pj = balls[j].position
                var dx = pj.x - pi.x
                var dy = pj.y - pi.y
                let distSq = dx*dx + dy*dy
                let minDist = 2 * r
                if distSq == 0 { continue }
                if distSq < minDist * minDist {
                    let dist = sqrt(distSq)
                    // Normal vector from i -> j
                    dx /= dist; dy /= dist
                    // Penetration depth
                    let penetration = minDist - dist
                    // Push them apart equally
                    let correction = penetration / 2
                    balls[i].position.x -= dx * correction
                    balls[i].position.y -= dy * correction
                    balls[j].position.x += dx * correction
                    balls[j].position.y += dy * correction

                    // Compute relative velocity along the normal
                    let vi = balls[i].velocity
                    let vj = balls[j].velocity
                    let rvx = vj.dx - vi.dx
                    let rvy = vj.dy - vi.dy
                    let relVelAlongNormal = rvx * dx + rvy * dy
                    if relVelAlongNormal > 0 { continue } // already separating

                    // Impulse scalar for equal masses
                    let jImpulse = -(1 + restitution) * relVelAlongNormal / 2
                    let impX = jImpulse * dx
                    let impY = jImpulse * dy

                    balls[i].velocity.dx -= impX
                    balls[i].velocity.dy -= impY
                    balls[j].velocity.dx += impX
                    balls[j].velocity.dy += impY
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                // Balls
                ForEach(Array(balls.enumerated()), id: \.element.id) { index, ball in
                    Circle()
                        .fill(
                            LinearGradient(colors: [ballColor.opacity(0.95), ballColor],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )
                        .frame(width: ballSize, height: ballSize)
                        .shadow(color: ballColor.opacity(0.6), radius: 10, x: 0, y: 6)
                        .position(x: ball.position.x, y: ball.position.y)
                        .accessibilityLabel("Bouncing Ball")
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if !isDragging {
                                        isDragging = true
                                        draggingBallIndex = index
                                        dragStartPosition = ball.position
                                        recentVelocities = []
                                        lastDragTime = value.time
                                        lastDragLocation = value.location
                                    }
                                    // Only respond to the active ball index
                                    guard draggingBallIndex == index else { return }

                                    let radius = ballSize / 2
                                    let clampedX = min(max(value.location.x, radius), geo.size.width - radius)
                                    let clampedY = min(max(value.location.y, radius), geo.size.height - radius)
                                    let newPos = CGPoint(x: clampedX, y: clampedY)

                                    let dt = max(1.0/240.0, lastDragTime.map { value.time.timeIntervalSince($0) } ?? (1.0/60.0))
                                    let dx = newPos.x - lastDragLocation.x
                                    let dy = newPos.y - lastDragLocation.y
                                    let instVel = CGVector(dx: dx / dt, dy: dy / dt)

                                    recentVelocities.append(instVel)
                                    if recentVelocities.count > 4 { recentVelocities.removeFirst() }

                                    lastDragTime = value.time
                                    lastDragLocation = newPos

                                    if let i = draggingBallIndex { balls[i].position = newPos }
                                }
                                .onEnded { value in
                                    // Only apply if this ball was the active drag target
                                    guard draggingBallIndex == index else { return }
                                    let count = recentVelocities.count
                                    if count > 0 {
                                        let sum = recentVelocities.reduce(CGVector(dx: 0, dy: 0)) { partial, v in
                                            CGVector(dx: partial.dx + v.dx, dy: partial.dy + v.dy)
                                        }
                                        let avg = CGVector(dx: sum.dx / CGFloat(count), dy: sum.dy / CGFloat(count))
                                        let perFrame = CGVector(dx: avg.dx / 60.0, dy: avg.dy / 60.0)
                                        let clamped = clampMagnitude(perFrame, max: terminalSpeed)
                                        if let i = draggingBallIndex { balls[i].velocity = clamped }
                                    }
                                    lastDragTime = nil
                                    recentVelocities = []
                                    isDragging = false
                                    draggingBallIndex = nil
                                }
                        )
                }

                // Controls overlay
                VStack {
                    Spacer()
                    HStack {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Button(isRunning ? "Pause" : "Resume") {
                                    isRunning.toggle()
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Reset") {
                                    reseedBalls(in: geo.size)
                                    initialVelocity = CGVector(dx: 3, dy: 4)
                                    ballSize = defaultBallSize
                                    ballColor = .blue
                                    isRainbowMode = false
                                    rainbowHue = 0.0
                                    isGravityEnabled = false
                                    isDragging = false
                                    dragStartPosition = .zero
                                    speedMultiplier = 1.0
                                }
                                .buttonStyle(.bordered)
                            }

                            Button(isGravityEnabled ? "Gravity: On" : "Gravity: Off") {
                                let wasOn = isGravityEnabled
                                isGravityEnabled.toggle()
                                if wasOn && !isGravityEnabled {
                                    // When turning gravity off, reset position to center and speed to defaults
                                    let radius = ballSize / 2
                                    let centerX = max(radius, min(geo.size.width - radius, geo.size.width / 2))
                                    let centerY = max(radius, min(geo.size.height - radius, geo.size.height / 2))
                                    for i in balls.indices {
                                        balls[i].position = CGPoint(x: centerX, y: centerY)
                                        balls[i].velocity = CGVector(dx: 3, dy: 4)
                                    }
                                    initialVelocity = CGVector(dx: 3, dy: 4)
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack(alignment: .center, spacing: 12) {
                            // Sliders on the left (size above speed)
                            VStack(alignment: .leading, spacing: 8) {
                                Slider(value: Binding(
                                    get: { ballSize },
                                    set: { newVal in ballSize = max(10, min(newVal, 120)) }
                                ), in: 10...120) {
                                    Text("Ball Size")
                                } minimumValueLabel: {
                                    Text("Small").font(.caption)
                                } maximumValueLabel: {
                                    Text("Large").font(.caption)
                                }
                                .tint(.blue)

                                HStack(spacing: 12) {
                                    Text("Speed").font(.caption)
                                    Slider(value: Binding(
                                        get: { speedMultiplier },
                                        set: { newVal in speedMultiplier = max(0.2, min(newVal, 3.0)) }
                                    ), in: 0.2...3.0)
                                    Text(String(format: "x%.1f", Double(speedMultiplier))).font(.caption)
                                }
                            }

                            // Color controls on the right
                            HStack(spacing: 8) {
                                ColorPicker("Ball Color", selection: $ballColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .frame(width: 44, height: 44)

                                Button(isRainbowMode ? "Rainbow: On" : "Rainbow: Off") {
                                    isRainbowMode.toggle()
                                }
                                .buttonStyle(.bordered)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Balls").font(.caption)
                                    TextField("Count", text: $ballCountText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .onSubmit {
                                            let n = Int(ballCountText) ?? ballCount
                                            ballCount = clampBallCount(n)
                                            ballCountText = String(ballCount)
                                            reseedBalls(in: geo.size)
                                        }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .readHeight { h in
                        controlsHeight = h
                    }
                }
            }
            .onAppear {
                // Start balls at positions on appear
                ballSize = defaultBallSize
                ballCount = clampBallCount(Int(ballCountText) ?? 1)
                ballCountText = String(ballCount)
                reseedBalls(in: geo.size)
            }
            .onReceive(Timer.publish(every: 1.0/60.0, on: .main, in: .common).autoconnect()) { _ in
                // Rainbow color cycling
                if isRainbowMode {
                    rainbowHue = (rainbowHue + 0.003).truncatingRemainder(dividingBy: 1.0)
                    withAnimation(.linear(duration: 1.0/60.0)) {
                        ballColor = Color(hue: rainbowHue, saturation: 0.9, brightness: 1.0)
                    }
                }

                // Gravity physics: apply acceleration and air drag when running and not dragging
                if isRunning && isGravityEnabled && !isDragging {
                    for i in balls.indices {
                        balls[i].velocity.dy += gravity
                        balls[i].velocity = clampMagnitude(balls[i].velocity, max: terminalSpeed)
                        balls[i].velocity.dx = applyAirDrag(balls[i].velocity.dx)
                        balls[i].velocity.dy = applyAirDrag(balls[i].velocity.dy)
                    }
                }
            }
            .onReceive(Timer.publish(every: 1.0/60.0, on: .main, in: .common).autoconnect()) { _ in
                guard isRunning && !isDragging else { return }

                let radius = ballSize / 2
                let minX = radius
                let maxX = geo.size.width - radius
                let maxY = geo.size.height - radius - controlsHeight
                let minY = radius

                for i in balls.indices {
                    if isGravityEnabled {
                        var vx = balls[i].velocity.dx * speedMultiplier
                        var vy = balls[i].velocity.dy * speedMultiplier
                        var newX = balls[i].position.x + vx
                        var newY = balls[i].position.y + vy
                        var collidedHorizontally = false
                        var collidedVertically = false
                        if newX <= minX { newX = minX; vx = -vx * restitution; collidedHorizontally = true }
                        else if newX >= maxX { newX = maxX; vx = -vx * restitution; collidedHorizontally = true }
                        if newY <= minY { newY = minY; vy = -vy * restitution; collidedVertically = true }
                        else if newY >= maxY { newY = maxY; vy = -vy * restitution; collidedVertically = true }
                        if collidedVertically { vx *= groundFriction }
                        if collidedHorizontally { vy *= groundFriction }
                        balls[i].velocity = CGVector(dx: vx / speedMultiplier, dy: vy / speedMultiplier)
                        balls[i].velocity.dx = zeroIfSmall(balls[i].velocity.dx)
                        balls[i].velocity.dy = zeroIfSmall(balls[i].velocity.dy)
                        balls[i].position = CGPoint(x: newX, y: newY)
                    } else {
                        var newX = balls[i].position.x + balls[i].velocity.dx * speedMultiplier
                        var newY = balls[i].position.y + balls[i].velocity.dy * speedMultiplier
                        if newX <= minX { newX = minX; balls[i].velocity.dx *= -1 }
                        if newX >= maxX { newX = maxX; balls[i].velocity.dx *= -1 }
                        if newY <= minY { newY = minY; balls[i].velocity.dy *= -1 }
                        if newY >= maxY { newY = maxY; balls[i].velocity.dy *= -1 }
                        balls[i].position = CGPoint(x: newX, y: newY)
                    }
                }
                resolveBallCollisions()
            }
        }
    }
}

#Preview {
    ContentView()
}

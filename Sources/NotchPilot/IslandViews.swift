import AppKit
import SwiftUI

// MARK: - Shape

/// Notch silhouette: flat top that flares outward with concave "ears",
/// rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, (rect.height) / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Transitions

private struct BlurModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.04)),
            removal: .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
                .animation(.easeOut(duration: 0.14))
        )
    }
}

// MARK: - Root

struct IslandRootView: View {
    @EnvironmentObject var state: IslandState
    @EnvironmentObject var np: NowPlayingService

    static let expandedWidth: CGFloat = 540

    var body: some View {
        let notch = state.notchSize
        let showWings = !state.expanded && (np.info?.playing ?? false)
        let wing = showWings ? notch.height + 6 : 0
        let top: CGFloat = state.expanded ? 14 : 7
        let bottom: CGFloat = state.expanded ? 32 : 11

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if state.expanded {
                    ExpandedView()
                        .padding(.horizontal, 22 + top)
                        .padding(.top, notch.height + 2)
                        .padding(.bottom, 18)
                        .frame(width: Self.expandedWidth)
                        .transition(.islandContent)
                } else {
                    CollapsedView(wing: wing)
                        .padding(.horizontal, top)
                        .frame(width: notch.width + 2 * top + 2 * wing, height: notch.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                }
            }
            .background(
                NotchShape(topRadius: top, bottomRadius: bottom)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.expanded ? 0.45 : 0), radius: 18, y: 10)
            )
            .clipShape(NotchShape(topRadius: top, bottomRadius: bottom))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { state.islandRect = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in state.islandRect = f }
                }
            )
            .contextMenu { IslandMenu() }
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.windowSize.width, height: NotchController.windowSize.height, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: showWings)
        .preferredColorScheme(.dark)
    }
}

struct IslandMenu: View {
    var body: some View {
        Button("Launch at Login") { LoginItem.toggle() }
        Divider()
        Button("Quit NotchPilot") { NSApp.terminate(nil) }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    var wing: CGFloat
    @EnvironmentObject var np: NowPlayingService
    @EnvironmentObject var state: IslandState

    var body: some View {
        HStack(spacing: 0) {
            if wing > 0 {
                ArtworkView(image: np.artwork, size: state.notchSize.height - 10, radius: 5)
                    .frame(width: wing, alignment: .leading)
                    .padding(.leading, 6)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                Spacer(minLength: 0)
                EqualizerBars(active: np.info?.playing ?? false)
                    .frame(width: 16, height: 12)
                    .frame(width: wing, alignment: .trailing)
                    .padding(.trailing, 10)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

struct EqualizerBars: View {
    var active: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.16)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let v = active ? 0.3 + 0.7 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i))) : 0.25
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2.5, height: 12 * v)
                        .animation(.easeInOut(duration: 0.16), value: v)
                }
            }
        }
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var mixer: MixerService
    @EnvironmentObject var toggles: QuickToggles

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaSection()
            ControlsRow()
            if !mixer.apps.isEmpty || mixer.lastError != nil {
                MixerSection()
            }
            if let msg = toggles.message {
                Text(msg).font(.system(size: 11)).foregroundStyle(.orange)
                    .onTapGesture { toggles.message = nil }
            }
        }
        .foregroundStyle(.white)
    }
}

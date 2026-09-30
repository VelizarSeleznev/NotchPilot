import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Media

struct MediaSection: View {
    @EnvironmentObject var np: NowPlayingService
    @EnvironmentObject var sessions: SessionTracker
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = np.info {
                HStack(spacing: 12) {
                    ArtworkView(image: np.artwork, size: 58, radius: 12)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                        .onTapGesture { if let cur = sessions.current { sessions.open(cur) } }
                        .help("Open source")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(subtitle(info)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    TransportButtons(playing: info.playing)
                }
                .id(info.title)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                ProgressBar(info: info)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "music.note.list").font(.system(size: 18)).foregroundStyle(.white.opacity(0.4))
                    Text(sessions.others.isEmpty ? "Nothing playing" : "Nothing playing — resume:")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(height: 30)
            }
            if !sessions.others.isEmpty {
                SessionStrip()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: np.info?.title)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sessions.others.map(\.id))
    }

    private func subtitle(_ info: NowPlayingInfo) -> String {
        let source = sessions.current?.sourceLabel
            ?? NSRunningApplication(processIdentifier: info.pid)?.localizedName
        return [info.artist, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct TransportButtons: View {
    var playing: Bool
    @EnvironmentObject var np: NowPlayingService

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.fill", size: 14) { np.send(.previous) }
            IconButton(symbol: playing ? "pause.fill" : "play.fill", size: 20, diameter: 40, filled: true) { np.send(.toggle) }
                .contentTransition(.symbolEffect(.replace))
            IconButton(symbol: "forward.fill", size: 14) { np.send(.next) }
        }
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat
    var diameter: CGFloat = 32
    var filled = false
    var action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .frame(width: diameter, height: diameter)
            .foregroundStyle(filled ? Color.black : Color.white)
            .background(Circle().fill(filled ? Color.white : Color.white.opacity(hover ? 0.12 : 0)))
            .scaleEffect(pressed ? 0.88 : 1)
            .contentShape(Circle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { pressed = true } } }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { pressed = false }
                        action()
                    }
            )
    }
}

struct ProgressBar: View {
    var info: NowPlayingInfo
    @EnvironmentObject var np: NowPlayingService
    @EnvironmentObject var state: IslandState
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = dragValue ?? info.position(at: ctx.date)
            let frac = info.duration > 0 ? min(max(pos / info.duration, 0), 1) : 0
            HStack(spacing: 8) {
                Text(format(pos)).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(dragValue == nil ? 0.8 : 1))
                            .frame(width: geo.size.width * frac)
                            .animation(dragValue == nil ? .linear(duration: 0.5) : nil, value: frac)
                    }
                    .frame(height: dragValue == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                state.interacting = true
                                guard info.duration > 0 else { return }
                                withAnimation(.easeOut(duration: 0.1)) {
                                    dragValue = min(max(g.location.x / geo.size.width, 0), 1) * info.duration
                                }
                            }
                            .onEnded { _ in
                                if let v = dragValue { np.seek(to: v) }
                                dragValue = nil
                                state.interacting = false
                            }
                    )
                }
                .frame(height: 14)
                Text(info.duration > 0 ? "-" + format(max(info.duration - pos, 0)) : "").monospacedDigit()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
        }
        .opacity(info.duration > 0 ? 1 : 0.4)
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Other things that were really listened to; one click pauses the current and resumes this.
struct SessionStrip: View {
    @EnvironmentObject var sessions: SessionTracker

    var body: some View {
        HStack(spacing: 8) {
            ForEach(sessions.others.prefix(3)) { s in
                SessionChip(session: s)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
    }
}

struct SessionChip: View {
    var session: MediaSession
    @EnvironmentObject var sessions: SessionTracker
    @State private var hover = false
    @State private var launched = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                ArtworkView(image: session.artworkData.flatMap(NSImage.init(data:)), size: 30, radius: 7)
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .opacity(hover ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(session.sourceLabel).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: 110, alignment: .leading)
        }
        .padding(5)
        .padding(.trailing, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.14 : 0.07)))
        .scaleEffect(launched ? 0.94 : 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { launched = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { launched = false }
            }
            sessions.switchTo(session)
        }
        .contextMenu {
            Button("Open") { sessions.open(session) }
            Button("Forget") { sessions.forget(session) }
        }
        .help("Pause current and play this")
    }
}

// MARK: - Controls

struct ControlsRow: View {
    @EnvironmentObject var outputs: OutputDeviceService
    @EnvironmentObject var toggles: QuickToggles
    @State private var showDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Pill(active: outputs.current?.isBluetooth ?? false, tint: .blue) {
                    outputs.cycle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: outputs.current?.symbol ?? "speaker.wave.2")
                            .font(.system(size: 13, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(outputs.current?.name ?? "No output").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showDevices ? 180 : 0))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDevices.toggle() }
                            }
                    }
                }
                .frame(maxWidth: .infinity)

                if toggles.xdrAvailable {
                    Pill(active: toggles.xdrOn, tint: .yellow) { toggles.toggleXDR() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: toggles.xdrOn ? "sun.max.fill" : "sun.max")
                                .font(.system(size: 13, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: toggles.xdrOn)
                            Text("XDR").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .help("BrightIntosh extra brightness")
                }
                if toggles.fansAvailable {
                    Pill(active: toggles.fansMax, tint: .cyan) { toggles.toggleFans() } label: {
                        HStack(spacing: 6) {
                            SpinningFan(spinning: toggles.fansMax)
                            Text(toggles.fansMax ? "Max" : "Auto").font(.system(size: 12, weight: .medium))
                                .contentTransition(.numericText())
                        }
                    }
                    .help("Fans: max / automatic")
                }
            }
            if showDevices {
                VStack(spacing: 2) {
                    ForEach(outputs.devices) { d in
                        DeviceRow(device: d, selected: d.id == outputs.currentID) {
                            outputs.select(d)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showDevices = false }
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }
}

struct DeviceRow: View {
    var device: OutputDevice
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.symbol).frame(width: 18)
            Text(device.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

struct Pill<Label: View>: View {
    var active: Bool
    var tint: Color
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        label()
            .padding(.horizontal, 12)
            .frame(height: 36)
            .foregroundStyle(active ? Color.black : Color.white)
            .background(
                Capsule().fill(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.15 : 0.09)))
            )
            .scaleEffect(pressed ? 0.95 : 1)
            .contentShape(Capsule())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .onTapGesture {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { pressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressed = false }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() }
            }
    }
}

struct SpinningFan: View {
    var spinning: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !spinning)) { ctx in
            Image(systemName: "fan.fill")
                .font(.system(size: 13, weight: .semibold))
                .rotationEffect(.degrees(spinning ? ctx.date.timeIntervalSinceReferenceDate * 540 : 0))
        }
    }
}

// MARK: - Mixer

struct MixerSection: View {
    @EnvironmentObject var mixer: MixerService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(mixer.apps) { app in
                MixerRow(app: app)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let err = mixer.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mixer.apps.map(\.id))
    }
}

struct MixerRow: View {
    var app: AudioApp
    @EnvironmentObject var mixer: MixerService
    @EnvironmentObject var state: IslandState

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .opacity(app.muted ? 0.35 : 1)
                if app.muted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 8, weight: .bold))
                        .padding(2).background(Circle().fill(.black)).offset(x: 3, y: 3)
                }
            }
            .onTapGesture { mixer.toggleMute(app) }
            .help(app.muted ? "Unmute" : "Mute")
            Text(app.name)
                .font(.system(size: 12, weight: app.isPlaying ? .medium : .regular))
                .foregroundStyle(.white.opacity(app.isPlaying ? 1 : 0.5))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            VolumeSlider(value: Binding(
                get: { Double(app.volume) },
                set: { mixer.setVolume(app, Float($0)) }
            ), dim: app.muted, editing: { state.interacting = $0 })
            Text("\(Int((app.muted ? 0 : app.volume) * 100))%")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 24)
    }

    private var icon: NSImage {
        if let path = app.bundlePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }
}

struct VolumeSlider: View {
    @Binding var value: Double
    var dim: Bool
    var editing: (Bool) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(Color.white.opacity(dim ? 0.3 : 0.85))
                    .frame(width: max(geo.size.height, geo.size.width * value))
            }
            .frame(height: active ? 8 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !active {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { active = true }
                            editing(true)
                        }
                        value = min(max(g.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { active = false }
                        editing(false)
                    }
            )
        }
        .frame(height: 16)
    }
}

// MARK: - Login item

enum LoginItem {
    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("NotchPilot login item: \(error)")
        }
    }
}

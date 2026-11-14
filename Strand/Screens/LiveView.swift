import SwiftUI
#if os(macOS)
import AppKit
#endif
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// Live — the connected strap in real time. Top to bottom: a status line (connection, battery, wear,
/// last sync), any pairing or reconnect notice, the live heart rate with its trace and the two
/// beat-to-beat figures, the session card, the connect / buzz / disconnect buttons and the Devices
/// row, then the signal checks and the strap log, folded. Built on ScreenScaffold and the Summary
/// cards, in the strap's blue with the heart rate in red.
///
/// LiveState (which publishes at ~1 Hz while a strap streams) is observed ONLY in leaf views
/// (`LiveHeartReadout`, `LivePhysiology`, `LiveHeaderStats`, `LiveSignalTrustRail`, `ActiveWorkoutLive`,
/// `LiveLogCard`, …) — the Today pattern — so a fresh HR / R-R / frame notify re-renders just that leaf,
/// never the whole screen. The parent only observes the coarse connection transitions it needs to re-arm
/// the stream and gate the layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Cross-screen navigation — drives the "Manage devices" affordance to the first-class Devices
    /// manager (where bands are paired / switched). The shell (sidebar on macOS, a sheet on iOS) routes
    /// the request; LiveView never needs to know which.
    @EnvironmentObject private var router: NavRouter

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// "Card transparency" (0–100, default 100): fades the live console cards in lockstep with the frosted
    /// cards; content stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// Maps the picked strap model to the HRV-reading source so the spot caveat is honest (#537): a
    /// WHOOP 5/MG's R-R is optical PPG (noisier), a WHOOP 4 is electrical R-R. Mirrors the Android
    /// `LiveScreen` mapping.
    private var hrvSnapshotSource: SpotHrvReading.Source {
        switch selectedModel {
        case .whoop5mg: return .opticalPPG
        case .whoop4:   return .chestStrap
        }
    }

    /// Effort display scale (#268) — routes the live + saved workout Effort read-outs. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Whether the ACTIVE registry device is a WHOOP, resolved once and handed to the leaves.
    private var activeIsWhoop: Bool {
        LiveConsoleReadout.activeIsWhoop(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// Whether the ACTIVE registry device is an Oura ring (#2305) — the ring-only affordances below.
    private var activeIsOura: Bool {
        LiveConsoleReadout.activeIsOura(
            devices: model.deviceRegistry?.devices ?? [],
            activeId: model.deviceRegistry?.activeDeviceId,
        )
    }

    /// The live ring's link phase, mirrored off the Oura source (#2305). Meaningful only under
    /// `activeIsOura`; `.disconnected` otherwise.
    private var ringPhase: OuraLiveSource.LinkPhase { model.ouraLinkPhase }

    /// A trusted WHOOP link, for the console readouts and the bond-only controls.
    ///
    /// Gated on the active device actually BEING a WHOOP (#2075). `LiveState` is one object that every
    /// live source writes into, so `connected && bonded` stays true for a bonded strap while an Oura
    /// ring is the device on screen. That showed the WHOOP pill, the WHOOP charge and live WHOOP-only
    /// controls under the ring's name, and made the pill's own ring branch unreachable, because this one
    /// is tested first.
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    /// A non-WHOOP live source (the Oura ring) that is connected and actively streaming live HR. It
    /// authenticates and streams but never reaches a WHOOP encrypted bond, so `bonded` stays false and
    /// `activeConnection` never trips — which left the console reading "stream not yet trusted" for a
    /// perfectly good ring stream. The status copy below treats this as a trusted live stream; the
    /// bond-only feature gates (buzz, alarm, HRV snapshot) keep keying off `activeConnection`. (#69 twin.)
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }

    /// The display name of the active device from the registry ("WHOOP", a strap's nickname, …) — what
    /// the user is connected to, or would connect to. Falls back to "WHOOP" before the registry opens or
    /// when none is resolvable, keeping the WHOOP-first tone. Drives the active-device readout + copy.
    private var activeDeviceName: String {
        guard let registry = model.deviceRegistry,
              let active = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        else { return "WHOOP" }
        return active.displayName
    }

    /// Live workout mode (#238) — presents the full in-exercise screen while a manual workout is
    /// active. Auto-opens when a workout begins; closing just hides it (the workout keeps recording).
    @State private var showLiveWorkout = false
    @State private var showStartSport = false
    @State private var confirmingEndWorkout = false

    /// Manual HRV snapshot (#127) — presents the "Take an HRV reading" screen as a sheet. Entry sits in
    /// the Session console and is only enabled while bonded (the reading needs the live R-R stream).
    @State private var showHRVSnapshot = false

    var body: some View {
        ScreenScaffold(title: "Live",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                consoleHeader
                    .staggeredAppear(index: 0)
                // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
                // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
                // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
                if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                // Primary Connect affordance, surfaced ABOVE the fold whenever there's no link. The real
                // Scan & Connect control otherwise lives in `controls` (below the Signal Trust grid), so
                // an offline user saw only inert copy up top. Gated purely on `!live.connected`, so it
                // disappears the instant the radio connects. Shared with macOS — it reuses `scanButton`,
                // which the wide layout already renders in `controls`.
                // WHOOP only (#2305): under a ring this card named the ring over a button that ran a
                // WHOOP scan — the #2303 reporter's Re-scan ran a full 5/MG handshake with the ring active.
                if activeIsWhoop, !live.connected { offlineConnectCallout }
                // The ring's own above-the-fold affordance: its link phase and a reconnect, shown until
                // `auth OK` — the same "no link yet" slot the WHOOP callout fills.
                if activeIsOura, ringPhase != .authenticated { ringConnectCallout }
                bodyConsole
                    .staggeredAppear(index: 1)
                // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
                // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
                // still works — this is informational, not an error — so it sits right under the readout in
                // a calm accent treatment rather than the amber warning banners above.
                if Self.shouldShowStandardHRNote(live.standardHRMode) {
                    standardHRNote(live.standardHRMode ?? "")
                }
                sessionConsole
                // Show the strap picker whenever we're not actively streaming, so a user with both a
                // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
                // sticky across disconnects — so after the first pairing the picker vanished for good.)
                // WHOOP only (#2305): `activeConnection` is false for a ring BY CONSTRUCTION, so without
                // the brand gate the WHOOP picker was shown MORE readily under a ring than under a strap.
                if activeIsWhoop, !activeConnection { modelPicker }
                // Scan / Buzz / Disconnect are the WHOOP path (`model.scan` → `BLEManager.connect`, the
                // explicit user-connect that bypasses the #1881 active-device gate on purpose). A ring
                // gets its own row; any other brand keeps the Devices row alone.
                if activeIsWhoop {
                    controls
                } else if activeIsOura {
                    ringControls
                }
                manageDevicesRow
                // The signal checks and the strap log are for when something looks wrong, so they wait
                // folded under the controls.
                FoldSection(symbol: "checkmark.shield.fill", title: "Signal checks",
                            accent: SummaryStyle.vitals, storageKey: "live.trust") {
                    signalTrustRail
                }
                FoldSection(symbol: "text.alignleft", title: "Strap log",
                            accent: Color(white: 0.5), storageKey: "live.log") {
                    LiveLogCard()
                }
            }
        }
        .onAppear { refreshLiveSession(); consumeActiveWorkoutRequest() }
        .onDisappear { model.stopRealtimeHR() }
        // A fresh bond/connection re-arms the BLE stream (Apple must re-send startRealtime on a new
        // connection) WITHOUT bumping the ref-count — `refreshLiveSession`'s `startRealtimeHR` already
        // counted this screen once on `.onAppear`, balanced by the single `stopRealtimeHR` above.
        // Re-counting here (multiple bonded/connected events per appearance, one disappear) would leave
        // the stream stuck armed after leaving Live (#681 ref-count balance).
        .onChangeCompat(of: live.bonded) { _ in reconnectLiveSession() }
        .onChangeCompat(of: live.connected) { _ in reconnectLiveSession() }
        // Live workout mode (#238): open the in-exercise screen the moment a workout starts.
        .onChangeCompat(of: model.activeWorkout != nil) { active in if active { showLiveWorkout = true } }
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model)
                .environmentObject(live)
        }
        // Pick a named sport before starting (#519) — the live workout view then opens
        // off the activeWorkout change above, so no extra navigation is needed here.
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in model.startWorkout(sport: name) }
        }
        // Manual HRV snapshot (#127) — a still, seated 60s R-R reading.
        .sheet(isPresented: $showHRVSnapshot) {
            // Tell the reading where its R-R is coming from so the caveat is honest (#537): a WHOOP 5/MG
            // derives R-R from the optical pulse signal (noisier) while a WHOOP 4 / chest strap is
            // electrical R-R. Driven off the picked strap model, mirroring the Android twin.
            HRVSnapshotView(onClose: { showHRVSnapshot = false }, source: hrvSnapshotSource)
                .environmentObject(model)
                .environmentObject(live)
        }
        .alert("End this workout?", isPresented: $confirmingEndWorkout) {
            Button("Cancel", role: .cancel) { }
            Button("End workout", role: .destructive) {
                model.endWorkout()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
    }

    // MARK: - Frosted card helper (matches LiquidTodayView.card: rounded 22 + resting hairline)

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    // MARK: - Status line

    /// The status at the top of the screen: one line saying whether the device is connected (and a
    /// sync counter while a history offload runs), then the device name with battery, wear and last
    /// sync. The battery / worn / sync figures live in the `LiveHeaderStats` leaf so their notifies
    /// don't re-render the whole screen.
    private var consoleHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                connectionPill
                Spacer(minLength: 8)
                if live.backfilling {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .accessibilityHidden(true)
                        Text("Syncing \(live.syncChunksThisSession)")
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.vitals)
                    .lineLimit(1)
                }
            }
            LiveHeaderStats(activeConnection: activeConnection, activeIsWhoop: activeIsWhoop,
                            deviceName: activeDeviceName)
        }
        .padding(.horizontal, 4)
    }

    private var connectionPill: some View {
        // Distinguish a GENUINE encrypted bond from the 5/MG live-HR shortcut that flips `bonded` true
        // over the unbonded standard profile (#69): blue "Streaming" only when encryptedBond, amber
        // "Live HR (not fully paired)" otherwise. The pairingHintBanner below gives the how-to.
        let (label, color): (String, Color) =
            (activeConnection && live.encryptedBond) ? (String(localized: "Streaming"), SummaryStyle.vitals)
            : activeConnection ? (String(localized: "Live HR (not fully paired)"), StrandPalette.statusWarning)
            : ringStreaming ? (String(localized: "Streaming"), SummaryStyle.vitals)
            : live.connected ? (String(localized: "Connected"), StrandPalette.statusWarning)
            : live.encryptedBond ? (String(localized: "Paired, idle"), StrandPalette.statusWarning)
            : (String(localized: "Disconnected"), StrandPalette.metricRose)
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SummaryStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Heart rate card (live BPM + live physiology)

    /// The screen's centrepiece: the live heart rate with its trace, and under a rule the two
    /// beat-to-beat figures. Both halves are leaf views that own LiveState so the 1 Hz HR / R-R
    /// notifies re-render only them, not the whole screen.
    private var bodyConsole: some View {
        SummaryCard(symbol: "heart.fill", title: "Heart rate", accent: SummaryStyle.heart) {
            LiveHeartReadout(activeIsWhoop: activeIsWhoop, activeIsOura: activeIsOura, hrMax: model.profile.hrMax)
                .padding(.top, 10)
            Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                .padding(.top, 12)
            LivePhysiology(activeIsWhoop: activeIsWhoop)
                .padding(.top, 12)
        }
    }

    // MARK: - Signal checks

    /// The signal checks: one row per signal that has to be current for the screen to be trustworthy
    /// (HR, R-R, connection, history sync, battery, wear, last frame and event). The whole list is a
    /// leaf that owns LiveState so its 1 Hz value refresh doesn't re-render the parent screen.
    private var signalTrustRail: some View {
        LiveSignalTrustRail(activeConnection: activeConnection, activeIsWhoop: activeIsWhoop)
    }

    // MARK: - Session console (record / inspect the current stream)

    @ViewBuilder private var sessionConsole: some View {
        if let w = model.activeWorkout {
            activeWorkoutCard(w)
        } else {
            SummaryCard(symbol: "figure.run", title: "Session", accent: SummaryStyle.activity) {
                VStack(alignment: .leading, spacing: 12) {
                    sessionPrompt
                    sessionActions
                }
                .padding(.top, 12)
            }
            if let last = model.lastWorkout {
                workoutSavedRow(last)
            }
        }
    }

    @ViewBuilder private var sessionPrompt: some View {
        if !activeConnection {
            Text("Connect the strap first, then mark a workout from the live stream.")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionActions: some View {
        VStack(spacing: NoopMetrics.rowSpacing) {
            // All three routed through the unified button system: a filled primary for the lead
            // action on its own row, secondary surfaces for the supporting two, which stack when
            // their labels do not fit side by side.
            NoopButton("Start workout", systemImage: "figure.run", kind: .primary, fullWidth: true) {
                showStartSport = true
            }
            .disabled(!activeConnection)
            .help("Track a workout manually. Records heart rate and effort until you end it.")

            NoopButtonRow(spacing: NoopMetrics.rowSpacing) {
                NoopButton("Refresh", systemImage: "arrow.clockwise", kind: .secondary, fullWidth: true) {
                    model.getBattery()
                }
                .disabled(!activeConnection)
                .help("Refresh strap battery and connection state.")

                // Manual HRV snapshot (#127) — a still, seated 60s R-R reading. Needs the live R-R
                // stream, so it's gated on a bonded connection just like the workout/refresh actions.
                NoopButton("HRV reading", systemImage: "waveform.path.ecg", kind: .secondary, fullWidth: true) {
                    showHRVSnapshot = true
                }
                .disabled(!activeConnection)
                .help(activeConnection
                      ? "Take a 60-second seated HRV reading from the live R-R stream."
                      : "Connect your strap first. The reading needs the live R-R stream.")
            }
        }
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(StrandPalette.metricRose).frame(width: 8, height: 8)
                    // "RECORDING" is a factual claim, and while paused nothing IS being recorded — the
                    // sample capture drops every reading. So the label swaps rather than gaining a tag
                    // beside it, which would leave the card asserting both at once. Reuses the "Paused"
                    // string #1533 already localized. (The Today card says "IN PROGRESS", which stays
                    // true while paused, so it keeps its label and takes the tag instead.)
                    Text(w.isPaused ? "Paused" : "RECORDING WORKOUT").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(w.isPaused ? StrandPalette.textSecondary : StrandPalette.metricRose)
                    Spacer()
                    // Re-render once a second so the elapsed clock ticks without a manual Timer.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveWorkoutClock.clock(Int(w.elapsed(at: context.date))))
                            .font(StrandFont.number(17)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                // Live HR / avg / peak / effort — the leaf owns LiveState + the active workout so the
                // 1 Hz stat refresh re-renders only these tiles, plus a liquid effort tube under them.
                ActiveWorkoutLive(workout: w, effortScale: effortScale)
                // The card used to offer End and nothing else, so the only IRREVERSIBLE control was the
                // one reachable without opening the live view, while Pause — the reversible one — was
                // not. Pause/Resume is one toggle (a paused session has exactly one sensible action), and
                // End moves to its own row so a destructive tap is not adjacent to a routine one.
                NoopButtonRow(spacing: NoopMetrics.rowSpacing) {
                    NoopButton(w.isPaused ? "Resume" : "Pause",
                               systemImage: w.isPaused ? "play.fill" : "pause.fill",
                               kind: .secondary, fullWidth: true) {
                        model.toggleWorkoutPause()
                    }
                    // Re-open the full live workout screen (#238) after it's been dismissed.
                    NoopButton("Open live view", systemImage: "rectangle.expand.vertical",
                               kind: .secondary, fullWidth: true) {
                        showLiveWorkout = true
                    }
                }
                NoopButton("End workout", systemImage: "stop.circle.fill",
                           kind: .destructive, fullWidth: true) {
                    confirmingEndWorkout = true
                }
            }
        }
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = [String(localized: "\(mins) min"), row.avgHr.map { String(localized: "\($0) avg bpm") },
                     row.strain.map { String(localized: "effort \(UnitFormatter.effortDisplay($0, scale: effortScale))") }].compactMap { $0 }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(SummaryStyle.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Workout saved")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
                Text(parts.joined(separator: ", "))
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// The shared layout of the pairing, reconnect and standard-HR notices: a glyph, a headline, the
    /// explanation, and an optional closing line, on a raised surface edged in the notice's colour.
    private func noticeBanner(symbol: String, tint: Color, title: LocalizedStringKey, detail: String,
                              closing: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SummaryStyle.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let closing {
                    Text(closing)
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .livePanel(edge: tint.opacity(0.5), edgeWidth: 1)
    }

    private func reconnectGuideBanner(_ guide: String) -> some View {
        noticeBanner(symbol: "exclamationmark.triangle.fill", tint: StrandPalette.statusWarning,
                     title: "Can't connect: your strap's pairing was reset", detail: guide)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reconnect help: \(guide)")
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        noticeBanner(symbol: "exclamationmark.triangle.fill", tint: StrandPalette.statusWarning,
                     title: "Live HR works. Free the strap to unlock buzz, alarms & sync", detail: hint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pairing help: \(hint)")
    }

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Calm inline note for the #80 low-bandwidth fallback. Unlike the amber pairing/reconnect banners this
    /// is NOT a warning — live HR is working — so it takes the strap's blue with a signal glyph. Same
    /// layout as the banners (icon + headline + explanation) for visual consistency.
    private func standardHRNote(_ detail: String) -> some View {
        noticeBanner(symbol: "antenna.radiowaves.left.and.right", tint: SummaryStyle.vitals,
                     title: "Standard HR mode (low bandwidth)", detail: detail,
                     closing: "Other metrics (R-R, frames, battery, history) need a full sync.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Standard HR mode, low bandwidth. \(detail)")
    }

    // MARK: - Strap picker

    /// Pick the strap family to scan for. Switching the selection drops the current strap's bond so the
    /// newly-picked one connects fresh — letting a user move between a WHOOP 4 and a 5/MG.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Strap")
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                SegmentedPillControl(
                    WhoopModel.allCases,
                    selection: Binding(
                        get: { selectedModel },
                        set: { newModel in
                            guard newModel.rawValue != selectedModelRaw else { return }
                            selectedModelRaw = newModel.rawValue
                            // Clear the previous strap's sticky bond/connection so the next scan targets the
                            // new family's service and bonds it fresh.
                            model.prepareStrapSwitch()
                        }
                    ),
                    label: { $0.displayName }
                )
                Spacer()
            }
            // Proactive 5/MG guidance: the strap bonds to one host at a time, so if it's still paired in
            // the official WHOOP app a scan here finds nothing. Offered the moment 5/MG is picked — not only
            // after a failed scan (#130) or a bond-refusal (which is the separate `pairingHint` banner).
            if selectedModel == .whoop5mg { whoop5PairingNote }
        }
        .padding(.horizontal, 4)
    }

    private var whoop5PairingNote: some View {
        InfoFold(title: "Scan finds nothing?") {
            Text("WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again.")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Offline connect callout

    /// The above-the-fold primary Connect affordance, shown only while `!live.connected`: a card naming
    /// the band Scan will connect to over a real, full-width `scanButton` (the same one `controls`
    /// renders below), so the offline state has an obvious action up top. Shared with macOS.
    @ViewBuilder private var offlineConnectCallout: some View {
        SummaryCard(symbol: "antenna.radiowaves.left.and.right", title: "Start a live stream",
                    accent: SummaryStyle.vitals) {
            VStack(alignment: .leading, spacing: 12) {
                Text(activeDeviceName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
                    .lineLimit(1)
                scanButton
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Manage devices link

    /// A persistent "where to pair / switch bands" row beneath the Scan / Disconnect controls. It sends
    /// the user to the first-class Devices manager and stays one tap away in every connection state,
    /// naming the active band so the link reads in context. The shell routes the request via `NavRouter` —
    /// macOS selects the Devices sidebar item, iOS presents the Devices screen.
    private var manageDevicesRow: some View {
        Button { router.openDevices() } label: {
            HStack(spacing: 14) {
                Image(systemName: "badge.plus.radiowaves.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SummaryStyle.vitals)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SummaryStyle.vitals.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage devices")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SummaryStyle.primary)
                    Text(activeDeviceName)
                        .font(.system(size: 14))
                        .foregroundStyle(SummaryStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SummaryStyle.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .livePanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Manage devices")
        .accessibilityHint("Opens the Devices screen, where you pair and switch bands.")
    }

    // MARK: - Controls

    private var controls: some View {
        // Three equal thirds can't hold all three labels at a legible size on a phone — the longest
        // ("Scan & Connect") truncates to "Scan &…" even after shrink-to-fit (#175). So on iOS the
        // primary action takes a full-width row and the two secondary actions share the row beneath,
        // stacking when their labels do not fit; macOS keeps the three-up row while it fits. (#175)
        #if os(iOS)
        VStack(spacing: NoopMetrics.rowSpacing) {
            scanButton
            NoopButtonRow(spacing: NoopMetrics.rowSpacing) {
                buzzButton
                disconnectButton
            }
        }
        #else
        NoopButtonRow(spacing: NoopMetrics.rowSpacing) {
            scanButton
            buzzButton
            disconnectButton
        }
        #endif
    }

    // MARK: - Ring controls (#2305)

    /// The ring's above-the-fold card while it is not yet authenticated: the honest phase line and the
    /// only ring reconnect in the app, with what Reconnect does behind an explanation row. Same slot
    /// as `offlineConnectCallout`, which is WHOOP-only.
    @ViewBuilder private var ringConnectCallout: some View {
        SummaryCard(symbol: "antenna.radiowaves.left.and.right", title: "Oura ring",
                    accent: SummaryStyle.vitals) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LiveRingCopy.status(ringPhase, streaming: false))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
                    .fixedSize(horizontal: false, vertical: true)
                ringReconnectButton
                InfoFold {
                    Text("Reconnect drops the current link, if any, and connects to the ring again. To pair or switch bands, open Devices.")
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
        }
    }

    /// The ring's row in the `controls` slot: one primary action. No Buzz (the ring has no haptic) and no
    /// Disconnect (a stopped ring source would not reconnect for the night; Devices is where a ring is
    /// deactivated).
    private var ringControls: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
            Text(LiveRingCopy.status(ringPhase, streaming: ringStreaming))
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            ringReconnectButton
        }
    }

    /// Drops the current ring link, if any, and connects again — `OuraLiveSource.reconnect()` through the
    /// coordinator, so it can only reach the ring that is the live source. Enabled in every phase: a ring
    /// parked in `.authenticating` (#2303) is exactly the case this exists for.
    private var ringReconnectButton: some View {
        NoopButton("Reconnect ring", systemImage: "arrow.clockwise",
                   kind: .primary, fullWidth: true) {
            model.reconnectOuraRing()
        }
    }

    // The connect / buzz / disconnect controls, all routed through the unified NOOP button system:
    // a filled primary for the lead Scan action, a secondary surface for Buzz, and the destructive
    // role for Disconnect — sentence-case, single line, optical-centred at controlHeight.
    private var scanButton: some View {
        NoopButton(live.connected ? "Re-scan" : "Scan & connect",
                   systemImage: "antenna.radiowaves.left.and.right",
                   kind: .primary, fullWidth: true) {
            model.scan(model: selectedModel)
        }
    }

    private var buzzButton: some View {
        NoopButton("Buzz strap", systemImage: "waveform.path",
                   kind: .secondary, fullWidth: true) {
            // #921: the confirmed one-shot sequence (pattern + RUN_ALARM, acked). A bare pattern
            // write here was the same silent no-buzz path the Siri shortcut hit on a WHOOP 4.0.
            model.buzzStrapOnce()
        }
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var disconnectButton: some View {
        NoopButton("Disconnect", systemImage: "xmark.circle",
                   kind: .destructive, fullWidth: true) {
            model.disconnect()
        }
        .disabled(!live.connected)
    }

    /// Live tab appeared: take a ref-count on the realtime stream (arms it on the 0→1 edge) and pull a
    /// battery reading. Balanced by the single `stopRealtimeHR()` on `.onDisappear`.
    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    /// Honour a one-shot "Return to workout" from the Today indicator card: present the in-exercise screen
    /// for an already-running workout, then clear the flag. The #238 "a workout just started" transition
    /// trigger never fires for a session that is already in flight, so this is the path that re-opens it.
    /// Guarded on a live `activeWorkout` so a stale flag can never present an empty live-workout sheet, and
    /// it sets the SAME `showLiveWorkout` one-shot the manual re-open button uses (no new sheet machinery).
    private func consumeActiveWorkoutRequest() {
        guard router.presentActiveWorkout else { return }
        router.presentActiveWorkout = false
        if model.activeWorkout != nil { showLiveWorkout = true }
    }

    /// A fresh bond/connection landed while the Live tab is up: re-arm the BLE stream (Apple re-sends
    /// startRealtime on a new connection) and refresh battery — WITHOUT taking another ref-count, since
    /// these events can fire several times per appearance against the single `.onDisappear` release.
    private func reconnectLiveSession() {
        guard activeConnection else { return }
        model.rearmRealtimeIfWanted()
        model.getBattery()
    }
}

// MARK: - Live leaves (each owns LiveState so a 1 Hz notify re-renders only the leaf — the Today pattern)

/// The header stats strip (device / battery / worn / last sync). Owns LiveState so battery + wear + sync
/// updates re-render only this row, never the whole console header.
private struct LiveHeaderStats: View {
    @EnvironmentObject private var live: LiveState
    let activeConnection: Bool
    /// Resolved by the parent (#2075), so the charge below can belong to the device being named.
    let activeIsWhoop: Bool
    let deviceName: String
    /// #218: an Oura ring streams live HR WITHOUT a WHOOP bond, so `activeConnection` (which needs the bond)
    /// is false for it and the wear stat read "—" mid-stream. A live HR stream is itself the wear signal
    /// (Oura only emits PPG HR while worn). `streamingLiveHR` is Oura-only, so this never widens WHOOP.
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    private var liveLink: Bool { activeConnection || ringStreaming }

    /// The ACTIVE device's charge (#2075). A non-WHOOP active device never falls back to the strap's
    /// number: an em dash says "not reported", where the strap's charge under the ring's name is a
    /// confident lie, and was exactly what the report saw.
    private var batteryLabel: String {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        ).map { "\($0)%" } ?? "—"
    }

    /// A streaming Oura ring is definitionally worn (PPG needs skin contact), and `worn` isn't reset on a
    /// source switch — so a stale `worn=false` from a prior WHOOP WRIST_OFF must not read "Off wrist"
    /// mid-stream. For WHOOP `ringStreaming` is always false, so this is just `live.worn`. #218.
    private var wornNow: Bool {
        // An Oura ring reports a precise live wear/charge state (live-HR presence + charger STATE + a
        // removal watchdog), so prefer it — it drops to not-worn the moment the ring is off the finger or
        // on the charger, unlike `ringStreaming`, which lingers. WHOOP has no such signal (ouraWearState
        // stays nil), so it keeps the bond-worn / stream fallback. #218.
        if let w = live.ouraWearState { return w == .worn }
        return live.worn || ringStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceName)
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .lineLimit(1)
            // Side by side while the three fit, one under another when they do not, so none is cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { stats }
                VStack(alignment: .leading, spacing: 6) { stats }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stats: some View {
        stat("battery.75percent", String(localized: "Battery"), batteryLabel)
        stat("sensor.tag.radiowaves.forward", String(localized: "Worn"),
             liveLink ? (wornNow ? String(localized: "Worn") : String(localized: "Not worn")) : "—")
        stat("arrow.triangle.2.circlepath", String(localized: "Last sync"), lastSyncLabel)
    }

    /// One figure of the status line: a glyph and its value. `title` is what VoiceOver reads before it.
    private func stat(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(SummaryStyle.vitals)
            Text(value)
                .font(SummaryStyle.number(15, .regular))
                .foregroundStyle(SummaryStyle.primary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private var lastSyncLabel: String { LiveSyncFormat.lastSyncLabel(live.lastSyncedAt) }
}

/// The heart rate card's top half: a beating heart beside the count-up numeral, the zone label, the
/// last two minutes as a trace, and one status line while there is no reading. Owns LiveState so the
/// ~1 Hz HR notify re-renders only this leaf.
private struct LiveHeartReadout: View {
    /// Resolved by the parent (#2075); this leaf does not re-derive it.
    let activeIsWhoop: Bool
    /// Resolved by the parent (#2305), same reason.
    let activeIsOura: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let hrMax: Int

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    /// The live HR zone for the zone label (presentation only). 0 = below Zone 1.
    private var liveZone: Int {
        guard let bpm = displayHR else { return 0 }
        return model.profile.hrZoneSet.zoneNumber(forBPM: Double(bpm))
    }

    @State private var shown: Double = 0
    /// The last two minutes of live heart rate, one value a second, drawn under the numeral.
    @State private var trace: [Double] = []
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                BeatingHeart(bpm: displayHR, size: 28)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The big focal HR numeral counts up to the live value (the hero number); a dash
                    // while there's no HR yet.
                    if displayHR != nil {
                        CountUpNumber(value: shown, font: SummaryStyle.number(76, .light))
                            .foregroundStyle(SummaryStyle.primary)
                    } else {
                        Text("–")
                            .font(SummaryStyle.number(76, .light))
                            .foregroundStyle(SummaryStyle.tertiary)
                    }
                    Text("bpm")
                        .font(.system(size: 20))
                        .foregroundStyle(SummaryStyle.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if liveZone >= 1 {
                    Text("Zone \(liveZone)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.hrZoneColor(liveZone))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(StrandPalette.hrZoneColor(liveZone).opacity(0.16)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Heart rate not available")
            if trace.count >= 2 {
                MotionTraceLine(values: trace)
                    .frame(height: 56)
                    .accessibilityHidden(true)
            }
            if let caption = statusCaption {
                Text(caption)
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { rollTo(displayHR) }
        .onChangeCompat(of: displayHR) { rollTo($0) }
        .onReceive(tick) { _ in
            // The trace only holds a current stream: it empties when the reading goes away.
            guard let hr = displayHR else {
                if !trace.isEmpty { trace.removeAll() }
                return
            }
            trace.append(Double(hr))
            if trace.count > 120 { trace.removeFirst(trace.count - 120) }
        }
    }

    /// Roll the count-up numeral to the new HR.
    private func rollTo(_ v: Int?) {
        guard let v else { shown = 0; return }
        withAnimation(.easeOut(duration: 0.6)) { shown = Double(v) }
    }

    /// One short line under the numeral while there is no reading; nil once heart rate is flowing,
    /// when the status line at the top of the screen already says so.
    private var statusCaption: String? {
        if displayHR != nil { return nil }
        // A ring reads its OWN phase (#2305, #2304): `live.connected` here is whichever source last
        // wrote it, and under a ring parked in the nonce handshake it read "Connected, waiting for a
        // streaming state" for an hour (#2303). The ring's phase is what the card should say.
        if activeIsOura { return LiveRingCopy.status(model.ouraLinkPhase, streaming: live.connected && live.streamingLiveHR) }
        if live.connected { return String(localized: "Connected, waiting for a streaming state.") }
        // The actionable Scan button lives in `offlineConnectCallout` above this card, so this stays
        // a calm empty-state line rather than a second, competing call to action.
        return String(localized: "No live stream.")
    }
}

/// The heart rate card's bottom half: the rolling variability and the latest beat interval, side by
/// side. Owns LiveState so the ~1 Hz R-R notifies re-render only this leaf, never the whole screen.
private struct LivePhysiology: View {
    @EnvironmentObject private var live: LiveState
    /// Resolved by the parent (#2075). Passed rather than observed so this leaf keeps owning only
    /// LiveState, which is what makes the ~1 Hz R-R notifies re-render it alone.
    let activeIsWhoop: Bool

    private var activeConnection: Bool { activeIsWhoop && live.connected && live.bonded }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            figure("Variability", rollingRMSSD.map { Int($0.rounded()) })
            // Offline the interval is a dash rather than the last value a previous link left behind.
            figure("Beat interval", activeConnection ? live.rr.last : nil)
        }
    }

    /// One live figure in milliseconds with its label above. A dash until there is a value.
    private func figure(_ label: LocalizedStringKey, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            SummaryValue(text: value.map { String($0) } ?? "–", unit: "ms", size: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
    /// clinical figure; it's blanked on disconnect by clearBiometrics). nil until ≥3 intervals land.
    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }
}

/// The Signal Trust rail's tiles. Owns LiveState so the value + tint refresh re-renders only the rail.
private struct LiveSignalTrustRail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let activeConnection: Bool
    /// Resolved by the parent (#2075): the battery tile below must describe the ACTIVE device.
    let activeIsWhoop: Bool

    /// The ACTIVE device's charge, or nil when it has not reported one.
    private var activeBatteryPct: Int? {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: activeIsWhoop, whoopPct: live.batteryPct, ringPct: live.ouraBatteryPct,
        )
    }

    private var displayHR: Int? { model.bpm }
    /// Oura ring actively streaming live HR — trusted stream without a WHOOP bond (see LiveView.ringStreaming).
    private var ringStreaming: Bool { live.connected && live.streamingLiveHR }
    /// #218: a live link for the wear stat = a WHOOP bond OR an Oura HR stream. Oura streams only while worn
    /// (PPG needs skin contact) and stops when removed, so `ringStreaming` doubles as its wear signal.
    private var liveLink: Bool { activeConnection || ringStreaming }
    /// Streaming ⟹ worn: keeps a stale `worn=false` (from a prior WHOOP WRIST_OFF, never reset on a source
    /// switch) from reading "Off wrist" while an Oura ring streams. For WHOOP `ringStreaming` is always
    /// false, so this is just `live.worn`. #218.
    private var wornNow: Bool {
        // An Oura ring reports a precise live wear/charge state (live-HR presence + charger STATE + a
        // removal watchdog), so prefer it — it drops to not-worn the moment the ring is off the finger or
        // on the charger, unlike `ringStreaming`, which lingers. WHOOP has no such signal (ouraWearState
        // stays nil), so it keeps the bond-worn / stream fallback. #218.
        if let w = live.ouraWearState { return w == .worn }
        return live.worn || ringStreaming
    }

    var body: some View {
        let tiles = signalTiles
        let recent = live.rrRecent.suffix(5).map { String($0) }.joined(separator: "  ")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { idx, tile in
                if idx > 0 {
                    Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                }
                SignalTrustTile(tile: tile)
            }
            if !recent.isEmpty {
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                Text(String(localized: "Recent intervals: \(recent) ms"))
                    .font(SummaryStyle.number(15, .regular))
                    .foregroundStyle(SummaryStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .livePanel()
    }

    private var connectionModeColor: Color {
        if (activeConnection && live.encryptedBond) || ringStreaming { return SummaryStyle.vitals }
        if activeConnection || live.connected { return StrandPalette.statusWarning }
        return StrandPalette.metricRose
    }

    private var batteryTint: Color {
        guard let pct = activeBatteryPct.map({ Double($0) }) else { return StrandPalette.textTertiary }
        if pct <= 15 { return StrandPalette.metricRose }
        if pct <= 30 { return StrandPalette.statusWarning }
        return SummaryStyle.vitals
    }

    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var syncDetail: String {
        if let err = live.lastSyncError { return err }
        if live.backfilling { return String(localized: "\(live.decodedChunksThisSession) decoded, \(live.consoleChunksThisSession) console") }
        return live.lastSyncedAt == nil ? String(localized: "No completed offload yet") : String(localized: "Last offload completed")
    }

    private var signalTiles: [SignalTrustTile.Model] {
        [
            .init(title: String(localized: "Heart rate"),
                  value: displayHR.map { "\($0) bpm" } ?? String(localized: "Missing"),
                  detail: (activeConnection || ringStreaming) ? String(localized: "Streaming now") : String(localized: "No active stream"),
                  icon: "waveform.path.ecg",
                  tint: displayHR == nil ? StrandPalette.textTertiary : SummaryStyle.heart,
                  frac: displayHR.map { min(1, Double($0) / Double(max(1, model.profile.hrMax))) }),
            .init(title: String(localized: "R-R intervals"),
                  value: live.rrRecent.isEmpty ? String(localized: "Missing") : String(localized: "\(live.rrRecent.count) recent"),
                  detail: rollingRMSSD.map { String(localized: "RMSSD \(Int($0.rounded())) ms") } ?? String(localized: "Needs interval frames"),
                  icon: "point.3.connected.trianglepath.dotted",
                  tint: live.rrRecent.isEmpty ? StrandPalette.textTertiary : SummaryStyle.heart,
                  frac: live.rrRecent.isEmpty ? nil : min(1, Double(live.rrRecent.count) / 30)),
            .init(title: String(localized: "Connection"),
                  value: activeConnection && live.encryptedBond ? String(localized: "Encrypted") : activeConnection ? String(localized: "Partial") : ringStreaming ? String(localized: "Streaming") : live.connected ? String(localized: "Connected") : String(localized: "Offline"),
                  detail: activeConnection && live.encryptedBond ? String(localized: "Controls unlocked") : ringStreaming ? String(localized: "Authenticated ring stream") : String(localized: "Standard HR is not a full bond"),
                  icon: "lock.shield",
                  tint: connectionModeColor,
                  frac: activeConnection && live.encryptedBond ? 1 : activeConnection ? 0.66 : ringStreaming ? 0.66 : live.connected ? 0.33 : nil),
            .init(title: String(localized: "History sync"),
                  value: live.backfilling ? String(localized: "\(live.syncChunksThisSession) chunks") : LiveSyncFormat.lastSyncLabel(live.lastSyncedAt),
                  detail: syncDetail,
                  icon: "clock.arrow.circlepath",
                  tint: live.backfilling ? SummaryStyle.vitals : StrandPalette.textSecondary,
                  frac: live.backfilling ? 0.6 : (live.lastSyncedAt == nil ? nil : 1)),
            .init(title: String(localized: "Battery"),
                  value: activeBatteryPct.map { "\($0)%" } ?? String(localized: "Unknown"),
                  // "by strap" only when a strap is what reported it (#2075).
                  detail: live.charging == true ? String(localized: "Charging")
                          : activeIsWhoop ? String(localized: "Last reported by strap")
                          : String(localized: "Last reported by the ring"),
                  icon: "battery.75percent",
                  tint: batteryTint,
                  frac: activeBatteryPct.map { max(0.02, min(1, Double($0) / 100)) }),
            // Wear is only trustworthy on a live link: `worn` defaults true (LiveState) and is only
            // updated by WRIST_ON/OFF events, so while OFFLINE it would otherwise read a false-green
            // "On wrist". Gate the value AND tint on a live link (triage fix for PR#191).
            // #218: `liveLink` includes an Oura HR stream, not just a WHOOP bond — an Oura ring streams
            // with no bond, so this read "Unknown" mid-stream. Oura emits PPG HR only while worn (and stops
            // when removed), so the stream itself is the wear signal; `worn` stays at its default true for
            // Oura until its WEAR_EVENT is wired to `worn` (follow-up).
            .init(title: String(localized: "Wear state"),
                  value: liveLink ? (wornNow ? String(localized: "On wrist") : String(localized: "Off wrist")) : String(localized: "Unknown"),
                  detail: liveLink ? (wornNow ? String(localized: "Eligible for live physiology") : String(localized: "Wear the strap for scoring")) : String(localized: "Connect to read wear state"),
                  icon: "sensor.tag.radiowaves.forward",
                  tint: !liveLink ? StrandPalette.textTertiary : wornNow ? SummaryStyle.vitals : StrandPalette.statusWarning,
                  frac: !liveLink ? nil : (wornNow ? 1 : 0.25)),
            // The last frame type and the last strap event, as the strap reported them. Offline they
            // read "Offline" rather than the value a previous link left behind.
            .init(title: String(localized: "Frame"),
                  value: activeConnection ? (live.lastFrameType ?? "—") : String(localized: "Offline"),
                  detail: "",
                  icon: "square.stack.3d.up",
                  tint: activeConnection ? SummaryStyle.vitals : StrandPalette.textTertiary,
                  frac: nil),
            .init(title: String(localized: "Event"),
                  value: activeConnection ? (live.lastEvent ?? "—") : String(localized: "Offline"),
                  detail: "",
                  icon: "bell",
                  tint: activeConnection ? SummaryStyle.vitals : StrandPalette.textTertiary,
                  frac: nil)
        ]
    }
}

/// The active-workout live stats (HR / avg / peak / effort) + a liquid effort tube. Owns LiveState +
/// AppModel so the 1 Hz HR/effort refresh re-renders only this block.
private struct ActiveWorkoutLive: View {
    @EnvironmentObject private var model: AppModel
    let workout: AppModel.ActiveWorkout
    let effortScale: EffortScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: NoopMetrics.gap) {
                stat("HR", model.bpm.map { "\($0)" } ?? "—",
                     tint: model.bpm == nil ? StrandPalette.textPrimary : StrandPalette.metricRose)
                stat(String(localized: "Avg"), workout.avgHr > 0 ? "\(workout.avgHr)" : "—")
                stat(String(localized: "Peak"), workout.peakHr > 0 ? "\(workout.peakHr)" : "—")
                stat(String(localized: "Effort"), UnitFormatter.effortDisplay(workout.liveStrain, scale: effortScale),
                     tint: StrandPalette.strainColor(workout.liveStrain))
            }
            // A liquid effort tube — the live effort as a fraction of the 0–100 strain axis.
            LiquidTube(frac: max(0, min(1, workout.liveStrain / 100)),
                       tint: StrandPalette.strainColor(workout.liveStrain), height: 10, animated: true)
                .accessibilityHidden(true)
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14))
                .foregroundStyle(SummaryStyle.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(SummaryStyle.number(22, .regular))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The strap log + export controls + Test Centre link. Wrapped in the liquid frosted card style.
///
/// This observes `LiveState` rather than scoping anything: a published change there invalidates every
/// observer, so what this card controls is the COST of its own re-evaluation, not whether it happens.
private struct LiveLogCard: View {
    /// How many trailing lines the card RENDERS. The buffer stays `LiveState.maxLogLines` (5,000) and Copy /
    /// Save / the export still read all of it, so nothing is lost by drawing less.
    ///
    /// #2521: this card used to render the whole buffer in a non-lazy `VStack`, so every appended line built
    /// and diffed up to 5,000 rows while the visible viewport is 200pt, about fifteen lines. A history drain
    /// plus a re-score burst emits hundreds of lines a minute, and the 80%-of-a-core CPU limit is per
    /// process, so that cost landed on the main thread and the app was killed with `cpu_resource_fatal`
    /// while it was not even frontmost.
    private static let renderedTailLines = 200

    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    /// Backgrounded, nothing is on screen to keep current, and a `LiveState` publish still re-evaluates this
    /// body because an `ObservableObject` invalidates every observer on ANY published change, not only the
    /// property a view reads. So what is cut is the COST of that re-evaluation, which is what the CPU limit
    /// measures: roughly fifteen built rows instead of five thousand, and none at all here.
    ///
    /// Not free, to be exact about what remains: the header, the `Divider` and the `NavigationLink` are still
    /// built per line, and `NavigationLink(destination:)` constructs `TestCentreView()` eagerly, which
    /// evaluates its `@State` defaults (three `UserDefaults` reads). Microseconds against the five thousand
    /// `Text` views this removes, but the place to look first if a background cost survives this.
    ///
    /// Gated on `.background` rather than `!= .active` deliberately: `.inactive` is also when iOS takes the
    /// app-switcher snapshot, and blanking the log there would be visible for no benefit. The kill needs
    /// sustained non-frontmost CPU, which is `.background`.
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                // Export the log so people can attach it to a bug report (issue #17 — macOS users
                // had no way to share it). Copy → clipboard; Save… → a .txt file.
                Button { copyStrapLog() } label: {
                    Text("Copy")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SummaryStyle.vitals)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { saveStrapLog() } label: {
                    Text("Save…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SummaryStyle.vitals)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            if scenePhase == .background {
                // Same height so returning to the app does not shift the card's layout.
                Color.clear.frame(height: 200)
            } else {
                logScroller
            }

            // Users look on Live first when something's wrong (#507/#509), so link straight into the
            // Test Centre diagnostic home, one tap from the log.
            Divider().overlay(StrandPalette.hairline)
            NavigationLink(destination: TestCentreView()) {
                HStack(spacing: 8) {
                    Image(systemName: "testtube.2").foregroundStyle(SummaryStyle.vitals)
                    Text("Open Test Centre to report a bug")
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.vitals)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SummaryStyle.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Test Centre")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    /// The tail of the log, lazily.
    ///
    /// The slice comes from `LiveState.renderedTail`, which snapshots the buffer so a lazily-realized row
    /// cannot index a trimmed array. Its indices are ABSOLUTE positions in `live.log`, which is what makes
    /// them usable as identity: BETWEEN trims, appending a line leaves every other row's id alone, so SwiftUI adds one row
    /// and drops one instead of re-identifying the list. A trim still renumbers, because `Array.removeFirst`
    /// shifts every element down, but that is once per `LiveState.trimSlack` lines and now touches 200 ids
    /// rather than rebuilding 5,000 rows.
    ///
    /// The old `id: \.offset` over `Array(live.log.enumerated())` paid on every line instead: a fresh
    /// 5,000-element array allocated per body evaluation, and a non-lazy `VStack` that built every row even
    /// though the 200pt viewport shows about fifteen.
    ///
    /// `scrollTo` still addresses the true last index, which is always inside the tail.
    private var logScroller: some View {
        let tail = LiveState.renderedTail(live.log, tailLines: Self.renderedTailLines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tail.indices, id: \.self) { idx in
                        Text(tail[idx]).font(StrandFont.mono)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .frame(height: 200)
            // On `logRevision`, not `log.count` (#2547). The revision is monotonic and ticks exactly once per
            // coalesced publish; the count plateaus while the ring trims, so it can stay equal across an
            // append and skip a scroll.
            .onChangeCompat(of: live.logRevision) { _ in
                if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    // The strap-log text builder lives on LiveState (`exportableLogText()`) so the macOS Settings
    // shortcut shares the exact same output (#17 / #507). These stay as thin wrappers.
    private func copyStrapLog() {
        PlatformPasteboard.copy(live.exportableLogText())
    }

    private func saveStrapLog() {
        Task {
            // Settings (#507) and Test Centre fetch these extras before exporting; without them this
            // site wrote a same-named file silently missing the "Strap & data" + funnel sections, so
            // which button someone pressed changed what a triager received.
            let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
            FileExport.exportText(live.exportableLogText(extraHeaderLines: extra),
                                  suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
        }
    }
}

// MARK: - Shared sync-label formatting

/// The "last sync" relative-time label — shared between the header stats and the Signal Trust rail so
/// both read identically.
private enum LiveSyncFormat {
    static func lastSyncLabel(_ ts: TimeInterval?) -> String {
        guard let ts else { return String(localized: "Never") }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Signal check row

/// One row of the signal checks: a glyph in the signal's colour, the signal's name with a one-line
/// detail under it, and the value at the trailing edge. The whole row is combined into a single
/// accessibility element so VoiceOver reads "Heart rate: 62 bpm. Streaming now." rather than three
/// disjoint fragments.
private struct SignalTrustTile: View {
    struct Model: Identifiable {
        let title: String
        let value: String
        let detail: String
        let icon: String
        let tint: Color
        /// 0...1 level of the signal (nil = no reading).
        let frac: Double?
        var id: String { title }
    }

    let tile: Model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tile.icon)
                .font(.system(size: 16))
                .foregroundStyle(tile.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title)
                    .font(.system(size: 16))
                    .foregroundStyle(SummaryStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !tile.detail.isEmpty {
                    Text(tile.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(SummaryStyle.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(tile.value)
                .font(SummaryStyle.number(16, .medium))
                .foregroundStyle(tile.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    /// What VoiceOver reads for the row: name and value, then the detail when there is one.
    private var spokenLabel: String {
        tile.detail.isEmpty ? "\(tile.title): \(tile.value)" : "\(tile.title): \(tile.value). \(tile.detail)"
    }
}

// MARK: - Shared surface

private extension View {
    /// The flat raised surface the Summary cards sit on, for this screen's rows and notices.
    func livePanel(edge: Color = Color.white.opacity(0.085), edgeWidth: CGFloat = 0.5) -> some View {
        background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(edge, lineWidth: edgeWidth))
    }
}

// MARK: - Ring status copy (#2305)

/// One line per ring link phase, shared by the console centrepiece caption, the above-the-fold callout
/// and the controls row so the three never disagree about what the ring is doing.
enum LiveRingCopy {
    static func status(_ phase: OuraLiveSource.LinkPhase, streaming: Bool) -> String {
        switch phase {
        case .disconnected:   return String(localized: "Ring not connected.")
        case .connecting:     return String(localized: "Connecting to the ring…")
        case .authenticating: return String(localized: "Connected, authenticating…")
        case .authenticated:
            return streaming
                ? String(localized: "Live heart rate is flowing from the ring.")
                : String(localized: "Connected, waiting for live heart rate.")
        }
    }
}

import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The shared explanation for an activity-masked gap on the Stress screen and hosted Today cards.
/// Whole-phrase singular/plural variants keep the sentence natural in every catalog locale.
func stressActivityMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour excluded — you were moving.")
        : String(localized: "\(count) hours excluded — you were moving.")
}

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number on a dial, a band (Low/Medium/High),
// and a single plain-English line on *why* behind one row. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the folded "How this is computed" group at the bottom.

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Whether TODAY's intraday timeline is scored against the PERSONAL cross-day daytime baseline
    /// (`.baselineRelative`, once enough worn history exists) instead of the day's own calm hours
    /// (`.dayRelative`). Drives only the explanatory copy — the 0–3 scale + bands are identical either way.
    @State private var daytimeUsesPersonalBaseline = false
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Stress",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Live / Sleep / Trends: a
                       // fixed, full-bleed time-of-day sky behind the scroll content (does not scroll), so the
                       // Stress screen sits in the same liquid atmosphere as every other tab.
                       topBackground: liquidScaffoldSky()) {
            if let model {
                content(model)
            } else if !loaded {
                ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
            } else {
                emptyState
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func load() async {
        guard let series = await StressLoadCancellation.read({
            await repo.series(key: "stress", source: "my-whoop")
        }) else { return }
        storedSeries = series
        loaded = true
        rebuildModelIfNeeded()
        await loadDaytime()
    }

    /// Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now]; the helper buckets it into waking hours and reuses the
    /// daily score's math, so this is the same proxy at a finer grain — never a new score.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        guard let hr = await StressLoadCancellation.read({
            await repo.hrSamples(from: from, to: to, limit: 200_000)
        }) else { return }
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        guard let rr = await StressLoadCancellation.read({
            await repo.rrIntervals(from: from, to: to, limit: 200_000)
        }) else { return }
        // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it
        // is masked rather than scored (DaytimeStress). Same store read as R-R; empty on hardware or
        // imports with no gravity, which is exactly the "no masking, prior behaviour" degradation.
        guard let gravity = await StressLoadCancellation.read({
            await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
        }) else { return }

        // Score today's hours against the PERSONAL cross-day daytime baseline ONLY when the user has
        // opted in (Settings → Experimental) AND enough worn history exists (Oura-style
        // `.baselineRelative`), else the day's own calm hours (`.dayRelative`, the default). The opt-in
        // gate is deliberate: the validated r≈0.6 margin is single-subject so far (#463), so this stays a
        // chooseable lens, not a silent default. The mode is resolved only AFTER the HR-count guard above,
        // so the trailing-history reads are never paid on a day with no scorable timeline — and are never
        // paid at all while the toggle is OFF (the default), keeping the read byte-identical to before.
        guard let mode = await StressLoadCancellation.read({
            await DaytimeStressMode.selected(
                repo: repo,
                startOfToday: startOfDay,
                calendar: cal,
                personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
            )
        }) else { return }
        // includeTimeline: the SLIDING read, so the screen's line moves in half-hours instead of
        // stepping through whole clock hours (#2144). The scored unit is still a full hour; this only
        // decides how often that hour is re-read, so a thin ten minutes costs the windows that overlap
        // it rather than a whole hour of chart. The Today card and the widget have always asked for
        // this; the screen people actually study was the one still stepping. Twin of the Kotlin change.
        // #2181: this is pure, database-free computation over a whole local day of samples, and it used
        // to run inline on this view's (main) actor. `analyze` memoises behind a lock-guarded
        // `AnalyticsMemoCache`, so it is safe off the main actor and the Today card already reads its own
        // stress the same way. Moving it here is what lets the timeline be published — and drawn — before
        // the advanced readouts below are started.
        //
        // `runUnescalated`, NOT `await Task.detached(...).value`: awaiting a task from a @MainActor
        // caller makes it a child and hands it the caller's priority, so a `.utility` label on a
        // detached task is decorative and the work races the UI for cores anyway. StressDayCurve
        // learned that on this same issue; the continuation in UnescalatedWork is what keeps the
        // priority honest.
        guard let timeline = await StressLoadCancellation.read({
            await runUnescalated(priority: .userInitiated) {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, mode: mode,
                                      includeTimeline: true)
            }
        }) else { return }
        daytime = timeline
        // Publish the mode with the timeline it describes, after the same cancellation check.
        if case .baselineRelative = mode { daytimeUsesPersonalBaseline = true }
        else { daytimeUsesPersonalBaseline = false }

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        // A SECOND hop on purpose (#2181). `HRVFreqDomain` is a Lomb-Scargle periodogram: its cost is
        // (clean beats x frequency-grid steps) with a transcendental per step, and it takes whatever beat
        // count the day's read returned — the store read above is bounded at 200 000, this is not bounded
        // at all. On a live-banked day that is seconds of arithmetic, and run inline it held the main
        // thread for all of them, which is why the screen stayed blank rather than drawing the timeline it
        // already had. Both engines are pure statics over the same `rr`, so they compute together off the
        // main actor and publish when done; their card is hidden until then, exactly as it is when a gate
        // is unmet. Same `runUnescalated` reasoning as above, and the default `.utility` is real here
        // because nothing escalates it: this is the phase that must yield to the UI.
        guard let advanced = await StressLoadCancellation.read({
            await runUnescalated {
                (index: StressIndex.components(rr: rr), freq: HRVFreqDomain.freqDomain(rr: rr))
            }
        }) else { return }
        stressIndex = advanced.index
        freqHRV = advanced.freq
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {

            // 1. Hero: today's 0-3 level on a dial, with the two markers it is built from.
            heroCard(model)
                .staggeredAppear(index: 0)

            // 2. Today's intraday trace, plus a passive Breathe suggestion when the recent hours
            //    stay elevated.
            // #2535: THREE states, not two. `daytime` is nil only while the read is still running, and this
            // used to render nothing then, so a fold that takes seconds looked exactly like a day with no
            // data. An empty `scored` after the read is a fact about the day and still stays silent.
            if daytime == nil {
                daytimeLoading()
                    .staggeredAppear(index: 1)
            } else if let daytime, !daytime.scored.isEmpty {
                dayCard(daytime)
                    .staggeredAppear(index: 1)
                // Sustained-high suggestion, only when the recent run stays in the HIGH band.
                if daytime.sustainedHigh {
                    sustainedBreatheCard(daytime)
                        .staggeredAppear(index: 2)
                }
            }

            // 3. Trend over the chosen window.
            trendCard(model)
                .staggeredAppear(index: 3)

            // 4. Advanced HRV readouts (additive, on-demand), folded. Present only when at least one
            //    engine returned a value; they never alter the hero, the markers or the timeline.
            if hasAdvancedReadouts {
                FoldSection(symbol: "waveform.path", title: "Advanced HRV", accent: SummaryStyle.heart,
                            storageKey: "stress.advanced") {
                    advancedReadoutsCard()
                }
                .staggeredAppear(index: 4)
            }

            // 5. Transparency: how the number is built, folded.
            FoldSection(symbol: "function", title: "How this is computed", accent: SummaryStyle.heart,
                        storageKey: "stress.method") {
                methodologyCard(model)
            }
            .staggeredAppear(index: 5)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") { showBreathe = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 520, height: 760)
            #endif
        }
    }

    // MARK: Shared pieces

    /// The half-point rule between the parts of a card.
    private var rule: some View {
        Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
    }

    /// One figure with its label above, sized to share a row with its neighbours.
    private func figure(_ label: LocalizedStringKey, _ text: String, unit: String = "",
                        color: Color = SummaryStyle.primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(SummaryStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            SummaryValue(text: text, unit: unit, size: 22, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A paragraph of explanation, as shown inside an `InfoFold`.
    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(SummaryStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 1 · Hero — today's level on a dial
    //
    // The 0–3 stress score reads as one number inside a three-quarter dial whose arc fills to score/3 in
    // the band colour (calm blue → steady green → tense amber). Beside it sit the two markers the score
    // is derived from, each against the 30-day baseline. The plain-English reading of the number waits
    // behind one row.

    private func heroCard(_ model: StressModel) -> some View {
        SummaryCard(symbol: "bolt.heart.fill", title: "Today", trailing: sourceLabel(model),
                    accent: SummaryStyle.heart) {
            HStack(alignment: .center, spacing: 18) {
                StressDial(score: model.score, band: model.band)
                    .frame(width: 148, height: 148)

                VStack(alignment: .leading, spacing: 12) {
                    // Resting HR: an INCREASE is the stressful direction.
                    marker("Resting pulse",
                           value: model.rhrToday.map { String($0) },
                           unit: "bpm",
                           delta: model.rhrDelta,
                           higherIsStress: true)
                    // HRV: a DECREASE is the stressful direction.
                    marker("Variability",
                           value: model.hrvToday.map { String(Int($0.rounded())) },
                           unit: "ms",
                           delta: model.hrvDelta,
                           higherIsStress: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.bottom, 6)

            InfoFold(title: "What it means") {
                Text(model.explanation)
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Marks a derived score as an estimate; a recorded daily score carries no label.
    private func sourceLabel(_ model: StressModel) -> LocalizedStringKey? {
        if model.usingStored { return nil }
        return "Estimate"
    }

    /// A vs-baseline marker beside the dial: label, value and how far it sits from the baseline.
    private func marker(_ label: LocalizedStringKey, value: String?, unit: String, delta: Double?,
                        higherIsStress: Bool) -> some View {
        let shift = markerShift(delta: delta, higherIsStress: higherIsStress)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(SummaryStyle.heart)
                .frame(width: 3, height: 52)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(SummaryStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                SummaryValue(text: value ?? "–", unit: value == nil ? "" : unit)
                if let text = shift.text {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(shift.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    /// The marker's distance from the baseline as text, tinted by whether the move is toward stress
    /// (warning) or recovery (positive).
    private func markerShift(delta: Double?, higherIsStress: Bool) -> (text: String?, color: Color) {
        // NO TEXT for a missing delta, rather than a claim we cannot make (#2145). It is nil when
        // today has no reading or there is no 30-day baseline to stand one against, and both used to
        // fall through to the at-baseline text: a marker with no reading read "— at baseline", and a
        // first-week marker put a reading exactly on a baseline that did not exist yet.
        guard let delta else { return (nil, SummaryStyle.tertiary) }
        if abs(delta) >= 0.5 {
            let up = delta > 0
            let isStressful = (up == higherIsStress)
            let text = String(localized: "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base")
            return (text, isStressful ? SummaryStyle.warn : SummaryStyle.tint)
        }
        return (String(localized: "at baseline"), SummaryStyle.secondary)
    }

    // MARK: 2 · Daytime timeline (intraday, same 0–3 proxy)

    /// The intraday timeline while its read is still running (#2535).
    ///
    /// Deliberately NOT the "no stress history" note: that is a conclusion, this says the answer is still
    /// being computed, which is what a caller waiting on the thirty-day fold needs to see. Keeps the header
    /// `dayCard` uses, so the card does not appear out of nowhere when the read lands; the height is
    /// approximate, not equal, since the real card carries a chart. Twin of the Kotlin
    /// `StressDaytimeLoading`.
    private func daytimeLoading() -> some View {
        SummaryCard(symbol: "clock", title: "Through the day", accent: SummaryStyle.heart) {
            Text("Reading today's heart rate…")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    private func dayCard(_ day: DaytimeStress.Result) -> some View {
        // The peak of what is DRAWN, not of the whole hours (#2144). A sliding window can exceed both
        // hourly neighbours when the busy stretch straddles a boundary, so `day.peak` would caption the
        // line with a number below its visible maximum. Everything that COUNTS hours still reads
        // `hours`; a maximum is not a count.
        let drawnPeak = day.timeline.filter { $0.level != nil }
            .max { ($0.level ?? 0) < ($1.level ?? 0) }

        return SummaryCard(symbol: "clock", title: "Through the day", accent: SummaryStyle.heart) {
            HStack(alignment: .top, spacing: 0) {
                figure("Average", day.dayMean.map { StressTrace.formatLevel($0) } ?? "–")
                if let peak = drawnPeak, let lvl = peak.level {
                    figure("Peak at \(clockLabel(peak.hour))", StressTrace.formatLevel(lvl),
                           color: StressRamp.color(lvl))
                } else {
                    figure("Peak", "–")
                }
                figure("Measured", String(day.scored.count), unit: "h")
            }
            .padding(.top, 12)

            // The day autonomic-load LINE, drawn with the same blue→green→amber ramp as the dial.
            // The SLIDING series, not the bare hours (#2144). Everything that COUNTS hours keeps
            // reading `hours`: the totals bars' shares still have to sum to the day. Only the line
            // and its ruler follow the finer read.
            DaytimeLoadLine(hours: day.timeline)
                .modifier(StressDrawIn())
                .padding(.top, 16)

            // Hour ruler under the line (first / midday / last covered hour).
            if let lo = day.timeline.first?.hour, let hi = day.timeline.last?.hour {
                HStack {
                    Text(hourLabel(lo))
                    Spacer()
                    Text(hourLabel((lo + hi) / 2))
                    Spacer()
                    Text(hourLabel(hi))
                }
                .font(.system(size: 13))
                .foregroundStyle(SummaryStyle.tertiary)
                .padding(.top, 6)
            }

            rule.padding(.vertical, 14)

            // The Calm / Moderate / High split: how many waking hours sat in each band.
            StressTotalsBar(totals: StressTotals(hours: day.hours))

            if let maskedCaption = stressActivityMaskedHoursCaption(day.activityMaskedHours) {
                Text(maskedCaption)
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            InfoFold {
                note(daytimeTimelineCaption)
            }
            .padding(.top, 6)
        }
    }

    /// The timeline's explanatory line, honest about WHICH reference each hour was scored against —
    /// the personal cross-day baseline (`.baselineRelative`) or the day's own calm hours (`.dayRelative`).
    /// Explicit `LocalizedStringKey` so BOTH variants stay in the string catalog (a ternary inside
    /// `Text(_:)` would resolve to the verbatim, non-localized `String` overload).
    private var daytimeTimelineCaption: LocalizedStringKey {
        daytimeUsesPersonalBaseline
            ? "The line is each waking hour's 0-3 proxy, scored against your personal daytime baseline (how your own days usually run). The bar below splits your day into calm, moderate and high stress time."
            : "The line is each waking hour's 0-3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time."
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        let elevated: LocalizedStringKey = "\(day.sustainedRun)h elevated"
        return SummaryCard(symbol: "lungs.fill", title: "Sustained high stress",
                           trailing: elevated, accent: SummaryStyle.warn) {
            Text("A few minutes of slow breathing help you settle.")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button {
                showBreathe = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wind")
                    Text("Start a Breathe session")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85)
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SummaryStyle.heart))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .softCardTransition()
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        hourDate(hour).formatted(.dateTime.hour())
    }

    /// The hour as a clock time ("14:00" / "2:00 PM"), for use inside a sentence.
    private func clockLabel(_ hour: Int) -> String {
        hourDate(hour).formatted(.dateTime.hour().minute())
    }

    /// Today at the given hour-of-day, wrapped into 0–23.
    private func hourDate(_ hour: Int) -> Date {
        let h = ((hour % 24) + 24) % 24
        return Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
    }

    // MARK: 3 · Trend (range-controlled)

    private func trendCard(_ model: StressModel) -> some View {
        let points = windowedTrend(model)
        return SummaryCard(symbol: "chart.xyaxis.line", title: "Trend", accent: SummaryStyle.heart) {
            if points.count >= 2 {
                let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                let highest = points.map(\.value).max() ?? 3
                // Axis top = highest reading rounded up, plus a little headroom, so a peak curve and
                // the top axis label clear the plot clip (#974). Floor of 1 keeps a flat calm history
                // from collapsing to a zero-height axis. The gradient stays on the full 0–3 scale
                // because TrendChart keys its colors off `valueRange`, not this domain.
                let yTop = max(1, highest.rounded(.up) + 0.3)

                // The one segmented control. Its eight options use the shared adaptive-width mode so
                // the control stays inside the card on compact iPhones.
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                TrendChart(
                    points: points,
                    gradient: StressRamp.gradient,
                    valueRange: 0...3,
                    showsArea: true,
                    height: NoopMetrics.chartHeight,
                    valueFormat: { StressTrace.formatLevel($0) },
                    accessibilityLabel: String(localized: "Stress trend"),
                    yDomain: 0...yTop
                )
                .modifier(StressDrawIn())
                .padding(.top, 14)

                rule.padding(.vertical, 14)

                HStack(alignment: .top, spacing: 0) {
                    figure("Average", StressTrace.formatLevel(avg), color: StressRamp.color(avg))
                    figure("Peak", StressTrace.formatLevel(highest), color: StressRamp.color(highest))
                    figure("Days", String(points.count))
                }

                rule.padding(.vertical, 14)

                // Share of the last 30 charted days that sat in the LOW band; independent of the range
                // control, which is why the row names its own window.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Low-stress days in the last 30")
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(model.calmTimeValue)
                        .font(SummaryStyle.number(20, .regular))
                        .foregroundStyle(SummaryStyle.primary)
                }
            } else {
                Text("Not enough recent days to chart a trend yet. Import a history or keep wearing your strap.")
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private func windowedTrend(_ model: StressModel) -> [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    // MARK: 4 · Advanced HRV readouts (additive, on-demand)
    //
    // Two extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced
    // in their own folded card so they are visibly separate from the 0..3 monitor. Each row is shown
    // only when its engine produced a value (the engines self-gate on clean-beat count / record span),
    // and the whole group is gated by `hasAdvancedReadouts`. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the advanced group is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    private func advancedReadoutsCard() -> some View {
        SummaryCard(symbol: "waveform.path.ecg", title: "Today", trailing: "Estimate",
                    accent: SummaryStyle.heart) {
            // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
            if let si = stressIndex {
                readout("Baevsky Stress Index", String(Int(si.si.rounded())))
            }

            // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for
            // LF (lfhf nil) fall back to the HF (rest) band power so the lens still reads.
            if let f = freqHRV {
                if let ratio = f.lfhf {
                    readout("Autonomic balance (LF/HF)", StressTrace.formatRatio(ratio))
                } else if f.hf > 0 {
                    readout("HF power", String(Int(f.hf.rounded())))
                }
            }

            rule.padding(.top, 10)

            InfoFold(title: "About these numbers") {
                VStack(alignment: .leading, spacing: 12) {
                    if stressIndex != nil {
                        note("Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm.")
                    }
                    if let f = freqHRV {
                        if f.lfhf != nil {
                            note("Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward).")
                        } else if f.hf > 0 {
                            note("Parasympathetic (rest) band of your HRV.")
                        }
                    }
                    note("These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above.")
                }
            }
        }
    }

    /// One advanced readout: its name on the left, its value on the right.
    private func readout(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(SummaryStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(value)
                .font(SummaryStyle.number(26))
                .foregroundStyle(SummaryStyle.primary)
        }
        .padding(.top, 14)
    }

    // MARK: 5 · Methodology (transparency)

    private func methodologyCard(_ model: StressModel) -> some View {
        SummaryCard(symbol: "ruler", title: "Scale", accent: SummaryStyle.heart) {
            HStack(spacing: 0) {
                bandLegend("0-1", "Low", StressRamp.calm)
                bandLegend("1-2", "Medium", StressRamp.steady)
                bandLegend("2-3", "High", StressRamp.tense)
            }
            .padding(.top, 14)

            Text(methodSummary(model))
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            InfoFold(title: "How it is calculated") {
                note("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
            }
            .padding(.top, 4)
        }
    }

    /// Where today's value came from, as an explicit `LocalizedStringKey` so both variants are
    /// looked up in the string catalog.
    private func methodSummary(_ model: StressModel) -> LocalizedStringKey {
        if model.usingStored { return "Today's value is your recorded daily stress score (0-3)." }
        return "Stress is derived from two autonomic signals."
    }

    private func bandLegend(_ range: String, _ label: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 16))
                    .foregroundStyle(SummaryStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(range)
                    .font(SummaryStyle.number(14, .regular))
                    .foregroundStyle(SummaryStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ComingSoon(what: "No stress history yet. Import your WHOOP export in Data Sources to see it.")
    }
}

// MARK: - Stress dial (three-quarter arc + count-up score)

/// Today's level as a three-quarter dial: a faint track in three band-coloured parts, an arc that
/// sweeps out to `score`/3 in the colour of the level, and the 0–3 value counting up in the middle
/// with its band word beneath. The arc is drawn at once when Reduce Motion is on.
private struct StressDial: View {
    /// The level, 0–3.
    let score: Double
    let band: StressBand

    /// False until the dial has appeared; the arc then sweeps out to its length.
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The part of the circle the dial covers.
    private let sweep = 0.75
    /// Trimmed off each end of a track part, so the rounded caps leave a gap between parts.
    private let inset = 0.016
    private let lineWidth: CGFloat = 10

    private var frac: Double { max(0, min(1, score / 3.0)) }

    var body: some View {
        let tracks: [Color] = [StressRamp.calm, StressRamp.steady, StressRamp.tense]
        let lit = inset + (sweep - 2 * inset) * frac
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: Double(i) * 0.25 + inset, to: Double(i + 1) * 0.25 - inset)
                    .stroke(tracks[i].opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .rotationEffect(.degrees(135))

            Circle()
                .trim(from: inset, to: drawn ? lit : inset)
                .stroke(StressRamp.color(score), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .opacity(drawn ? 1 : 0)
                .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.9).delay(0.2), value: drawn)
                .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.5), value: score)

            VStack(spacing: 0) {
                // CountUpText self-animates (counts up from 0 on appear, re-rolls on value change),
                // so the score is passed straight through.
                CountUpText(
                    value: score,
                    format: { StressTrace.formatLevel($0) },
                    font: SummaryStyle.number(52),
                    color: SummaryStyle.primary
                )
                Text(band.word)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StressRamp.color(score))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 18)
        }
        .padding(lineWidth / 2)
        .overlay(alignment: .bottom) {
            Text("of 3")
                .font(.system(size: 13))
                .foregroundStyle(SummaryStyle.tertiary)
        }
        .onAppear { drawn = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Stress \(StressTrace.formatLevel(score)) of 3"))
    }
}

/// Reveals a chart from its leading edge when it first appears. Shown at once with Reduce Motion on.
private struct StressDrawIn: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle()
                    .scaleEffect(x: (shown || reduceMotion) ? 1 : 0, y: 1, anchor: .leading)
            }
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = true }
                }
            }
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }

    /// The band as a word in sentence case, shown under the number on the dial.
    var word: String {
        switch self {
        case .low:    return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high:   return String(localized: "High")
        }
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// dial arc, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent         // #60A0E0 — calm WHOOP blue
    static let steady  = StrandPalette.statusPositive // #03E095 — balanced WHOOP green
    static let tense   = StrandPalette.statusWarning  // #F0A020 — high WHOOP amber

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
        // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
        // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead of
        // calibrating, the same last-night carry every other Today vital uses. The predicate mirrors the
        // storedToday||derived gate below, so an imported stress-only latest day is still honored (not
        // skipped). Falls back to the last row when no day has any signal (cold start).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last
        else { return nil }   // no days at all
        let today = days[idx]

        // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
        // against its own recent past rather than itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // y maps a 0–3 level into the chart (0 at bottom), for the baseline rule below. The x
            // placement moved into `scoredRuns`, which needs it per point anyway.
            // (a closure, not a `func` — a `@ViewBuilder` closure can't contain declarations)
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            // Contiguous runs of scored hours. Built in a method, not here: this is a
            // `@ViewBuilder` closure and cannot hold statements.
            let runs = scoredRuns(width: w, height: h)

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The ramp runs DOWN the chart, not across the day.
                //
                // It used to be `.leading` to `.trailing`, which painted the stress band colours along
                // the x-axis: a calm 9pm hour rendered amber and a tense 7am one blue, so the colour
                // said nothing about the score while looking exactly as though it did. Because y maps
                // the 0-3 level onto the chart, a vertical ramp makes vertical position the level, which
                // is what the Kotlin twin does and what the legend claims. Amber at the top, blue at the
                // bottom: `StressRamp.gradient` runs calm-first, so it is reversed here.
                let levelRamp = LinearGradient(
                    gradient: Gradient(colors: Array(StressRamp.stops.map(\.color).reversed())),
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(runs.enumerated()), id: \.offset) { _, seg in
                    if seg.count >= 2 {
                        // Closed PER RUN, so the wash cannot spread under an hour that was never scored
                        // and undo the gap the broken line just drew.
                        areaPath(seg, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        StressRamp.calm.opacity(0.22),
                                        StressRamp.calm.opacity(0.02),
                                    ]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(seg)
                            .stroke(levelRamp,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    } else if let only = seg.first {
                        // A run of one scored hour: a dot rather than a line. Coloured by the level it
                        // actually carries — it used to be hardcoded to the mid colour, so a lone HIGH
                        // hour drew as an ordinary one.
                        Circle()
                            .fill(StressRamp.color(level(at: only.1, height: h)))
                            .frame(width: 6, height: 6)
                            .position(x: only.0, y: only.1)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// CONTIGUOUS RUNS of scored hours, in chart coordinates.
    ///
    /// The old path `compactMap`-ed the unscored hours away and stroked a smooth curve through whatever
    /// was left, which draws a reading straight across an hour that has none — the one thing the caption
    /// promises it will not do. Splitting into runs lets each be stroked and filled separately, so a
    /// hole in the day stays a hole. The Kotlin twin has always broken the line here.
    private func scoredRuns(width w: CGFloat, height h: CGFloat) -> [[(CGFloat, CGFloat)]] {
        let n = max(hours.count, 1)
        var out: [[(CGFloat, CGFloat)]] = []
        var run: [(CGFloat, CGFloat)] = []
        for (i, p) in hours.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            let px = n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1)
            let py = h - h * CGFloat(min(max(level / 3.0, 0), 1))
            run.append((px, py))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// The 0-3 level a chart y-position represents: the inverse of the `y` mapping above, so a lone
    /// point can be coloured by what it actually reads rather than by a fixed guess.
    private func level(at yPos: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height - yPos) / height) * 3.0
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

// MARK: - Stress totals bars
//
// The Calm / Moderate / High split of the scored day, rendered as three labelled bars. Each bar grows
// to that band's SHARE of the scored day and is tinted to the band's colour (calm blue / steady green /
// tense amber), with the band name + its duration above it. A day with no scored hours leaves all
// three bars empty (no fabricated fill).

struct StressTotalsBar: View {
    let totals: StressTotals

    /// False until the bars have appeared; they then grow out to their share.
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Band {
        let band: StressBand
        let label: LocalizedStringKey
        let color: Color
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: "Calm",     color: StressRamp.calm),
            Band(band: .medium, label: "Moderate", color: StressRamp.steady),
            Band(band: .high,   label: "High",     color: StressRamp.tense),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<bands.count, id: \.self) { i in
                let b = bands[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label)
                            .font(.system(size: 15))
                            .foregroundStyle(SummaryStyle.primary)
                        Spacer()
                        Text(durationLabel(totals.hours(b.band)))
                            .font(SummaryStyle.number(15, .regular))
                            .foregroundStyle(SummaryStyle.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.09))
                            Capsule()
                                .fill(b.color)
                                .frame(width: grown ? geo.size.width * CGFloat(totals.fraction(b.band)) : 0)
                                .animation(reduceMotion ? nil : Animation.spring(response: 0.6, dampingFraction: 0.85)
                                    .delay(0.2 + 0.08 * Double(i)), value: grown)
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .onAppear { grown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Today's stress split: calm \(durationLabel(totals.calmHours)), moderate \(durationLabel(totals.moderateHours)), high \(durationLabel(totals.highHours)).")
        )
    }

    /// "—" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : String(localized: "\(hours)h")
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

/// A sample waking-hour timeline (06:00→22:00) for the preview, with a couple of
/// no-signal gaps so the line break reads honestly.
private func sampleDaytimeHours() -> [DaytimeStress.HourPoint] {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    return (DaytimeStress.wakingStartHour...DaytimeStress.wakingEndHour).map { h in
        let curve = 1.3 + 1.1 * sin(Double(h - 6) / 3.2)
        // Drop two hours to show the gap behaviour.
        let level: Double? = (h == 11 || h == 17) ? nil : min(max(curve, 0), 3)
        return DaytimeStress.HourPoint(hour: h, startTs: base + h * 3600,
                                       level: level, meanHR: 64, rmssd: 38)
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        let hours = sampleDaytimeHours()
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                // Hero: the dial with the band word, and the plain-English line.
                SummaryCard(symbol: "bolt.heart.fill", title: "Today", accent: SummaryStyle.heart) {
                    StressDial(score: score, band: band)
                        .frame(width: 148, height: 148)
                        .padding(.top, 14)
                    Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }

                // Day autonomic-load line + Calm/Moderate/High totals bars.
                SummaryCard(symbol: "clock", title: "Through the day", accent: SummaryStyle.heart) {
                    DaytimeLoadLine(hours: hours)
                        .padding(.top, 14)
                    StressTotalsBar(totals: StressTotals(hours: hours))
                        .padding(.top, 14)
                }

                SummaryCard(symbol: "chart.xyaxis.line", title: "Trend", accent: SummaryStyle.heart) {
                    SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                         adaptsToAvailableWidth: true) { $0.label }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { StressTrace.formatLevel($0) })
                        .padding(.top, 14)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress — HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress — LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import StrandAnalytics
import StrandDesign
#if canImport(MuscleMap)
import MuscleMap
#endif

// MARK: - Exercise library

/// One exercise from the bundled list (free-exercise-db, public domain). The two photos of each
/// exercise are loaded from that project's repository when shown; nothing else leaves the phone.
struct LibraryExercise: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    /// The muscle the exercise mainly works, in the list's own vocabulary ("chest", "middle back").
    let muscle: String
    /// Muscles that help.
    let secondary: [String]
    let equipment: String
    let category: String
    let images: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        muscle = try c.decode(String.self, forKey: .muscle)
        secondary = (try? c.decode([String].self, forKey: .secondary)) ?? []
        equipment = (try? c.decode(String.self, forKey: .equipment)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
    }

    var imageURLs: [URL] {
        images.compactMap { path in
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/" + escaped)
        }
    }
}

enum ExerciseLibrary {
    static let all: [LibraryExercise] = {
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([LibraryExercise].self, from: data) else { return [] }
        return list.sorted { $0.name < $1.name }
    }()

    static func find(_ id: String) -> LibraryExercise? {
        all.first { $0.id == id }
    }
}

// MARK: - Learned profiles

/// What the counter has learned about one exercise from sets the wearer marked by hand.
struct RepProfile: Codable {
    var exerciseId: String
    var name: String
    var settings: RepCounter.Settings
    /// Swing of the last marked set, in degrees.
    var swingDegrees: Double
    /// Seconds per repetition in the last marked set.
    var secondsPerRep: Double
    /// How many marked sets this profile has seen.
    var markedSets: Int
}

enum RepProfileStore {
    private static let key = "repCounter.profiles.v1"

    static func all() -> [String: RepProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: RepProfile].self, from: data) else { return [:] }
        return stored
    }

    static func profile(for exerciseId: String) -> RepProfile? {
        all()[exerciseId]
    }

    static func save(_ profile: RepProfile) {
        var stored = all()
        stored[profile.exerciseId] = profile
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Muscle groups

/// The muscle vocabulary of the exercise list, in the order the picker shows it.
enum MuscleGroups {
    static let all = ["chest", "shoulders", "biceps", "triceps", "forearms", "abdominals", "lats",
                      "middle back", "lower back", "traps", "quadriceps", "hamstrings", "glutes",
                      "calves", "adductors", "abductors", "neck"]

    static func title(_ name: String) -> LocalizedStringKey {
        switch name {
        case "chest": return "Chest"
        case "shoulders": return "Shoulders"
        case "biceps": return "Biceps"
        case "triceps": return "Triceps"
        case "forearms": return "Forearms"
        case "abdominals": return "Abs"
        case "lats": return "Lats"
        case "middle back": return "Middle back"
        case "lower back": return "Lower back"
        case "traps": return "Traps"
        case "quadriceps": return "Quads"
        case "hamstrings": return "Hamstrings"
        case "glutes": return "Glutes"
        case "calves": return "Calves"
        case "adductors": return "Adductors"
        case "abductors": return "Abductors"
        case "neck": return "Neck"
        default: return LocalizedStringKey(name.capitalized)
        }
    }
}

/// A front and a back figure with muscles filled by strength, 0 (not shown) to 1 (full colour).
struct MuscleFigure: View {
    let levels: [String: Double]

    var body: some View {
        #if canImport(MuscleMap)
        HStack(spacing: 4) {
            figure(.front)
            figure(.back)
        }
        .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }

    #if canImport(MuscleMap)
    private static let names: [String: [Muscle]] = [
        "chest": [.chest], "shoulders": [.deltoids], "biceps": [.biceps], "triceps": [.triceps],
        "forearms": [.forearm], "abdominals": [.abs, .obliques], "lats": [.upperBack],
        "middle back": [.rhomboids, .upperBack], "lower back": [.lowerBack], "traps": [.trapezius],
        "quadriceps": [.quadriceps], "hamstrings": [.hamstring], "glutes": [.gluteal],
        "calves": [.calves], "adductors": [.adductors], "abductors": [.gluteal], "neck": [.neck],
    ]

    private func figure(_ side: BodySide) -> some View {
        let base = Color(white: 0.2)
        let style = BodyViewStyle(defaultFillColor: base, headColor: base, hairColor: base)
        var strongest: [Muscle: Double] = [:]
        for (name, level) in levels where level > 0 {
            for muscle in Self.names[name] ?? [] {
                strongest[muscle] = max(strongest[muscle] ?? 0, min(level, 1))
            }
        }
        var view = BodyView(gender: .male, side: side, style: style)
        for (muscle, level) in strongest {
            view = view.highlight(muscle, color: SummaryStyle.activity, opacity: 0.3 + 0.7 * level)
        }
        return view.frame(maxWidth: .infinity)
    }
    #endif
}

extension LibraryExercise {
    /// Fill levels for the figure: the main muscle full, the helpers lighter.
    var muscleLevels: [String: Double] {
        var out: [String: Double] = [:]
        for name in secondary { out[name] = 0.35 }
        out[muscle] = 1
        return out
    }
}

// MARK: - Set history

/// One finished set, kept so the app can show what each muscle group has done.
struct RepSetRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var exerciseId: String
    var name: String
    var muscle: String
    var secondary: [String]
    var reps: Int
    var seconds: Int
    var weightKg: Double
}

enum RepSetStore {
    private static let key = "repCounter.sets.v1"
    private static let weightsKey = "repCounter.lastWeight.v1"

    static func all() -> [RepSetRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([RepSetRecord].self, from: data) else { return [] }
        return stored
    }

    static func append(_ record: RepSetRecord) {
        var stored = all()
        stored.append(record)
        if stored.count > 5_000 { stored.removeFirst(stored.count - 5_000) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// The weight last used for an exercise, in kilograms; 0 when none was entered.
    static func lastWeight(for exerciseId: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: weightsKey)?[exerciseId] as? Double) ?? 0
    }

    static func setLastWeight(_ kg: Double, for exerciseId: String) {
        var stored = UserDefaults.standard.dictionary(forKey: weightsKey) ?? [:]
        stored[exerciseId] = kg
        UserDefaults.standard.set(stored, forKey: weightsKey)
    }

    /// Sets per muscle group over the last `days` days. A set counts one for the exercise's main
    /// muscle and a half for each helper, the usual way weekly training volume is tallied.
    static func setsPerMuscle(days: Int, records: [RepSetRecord]) -> [String: Double] {
        let from = Date().addingTimeInterval(-Double(days) * 86_400)
        var out: [String: Double] = [:]
        for record in records where record.date >= from && record.reps > 0 {
            if !record.muscle.isEmpty { out[record.muscle, default: 0] += 1 }
            for helper in record.secondary { out[helper, default: 0] += 0.5 }
        }
        return out
    }
}

// MARK: - Views

/// The exercise's two photos shown in turn, which reads as the movement.
struct ExerciseAnimation: View {
    let exercise: LibraryExercise

    var body: some View {
        let urls = exercise.imageURLs
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.9)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.9) % 2
            ZStack {
                StrandPalette.surfaceInset
                ForEach(0..<min(urls.count, 2), id: \.self) { index in
                    AsyncImage(url: urls[index]) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .opacity(urls.count < 2 || index == phase ? 1 : 0)
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Search the library, narrow it by muscle group and pick one exercise. Exercises the counter has
/// already learned come first.
struct ExercisePickerView: View {
    @Binding var selection: LibraryExercise?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group: String?

    private func results(learned: [String: RepProfile]) -> [LibraryExercise] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = ExerciseLibrary.all.filter { exercise in
            (group == nil || exercise.muscle == group)
                && (text.isEmpty || exercise.name.lowercased().contains(text))
        }
        return matching.filter { learned[$0.id] != nil } + matching.filter { learned[$0.id] == nil }
    }

    var body: some View {
        let learned = RepProfileStore.all()
        let list = results(learned: learned)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose exercise")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SummaryStyle.primary)
                Spacer()
                Button("Close") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundStyle(SummaryStyle.activity)
            }
            .padding(.horizontal, 18)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SummaryStyle.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset))
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", selected: group == nil) { group = nil }
                    ForEach(MuscleGroups.all, id: \.self) { name in
                        chip(MuscleGroups.title(name), selected: group == name) { group = name }
                    }
                }
                .padding(.horizontal, 18)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { exercise in
                        Button {
                            selection = exercise
                            dismiss()
                        } label: {
                            row(exercise, learned: learned[exercise.id] != nil)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.leading, 106)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 18)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : SummaryStyle.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(selected ? SummaryStyle.activity : StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    private func row(_ exercise: LibraryExercise, learned: Bool) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: exercise.imageURLs.first) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                StrandPalette.surfaceInset
            }
            .frame(width: 92, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.name)
                    .font(.system(size: 17))
                    .foregroundStyle(SummaryStyle.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(MuscleGroups.title(exercise.muscle))
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
            }
            Spacer(minLength: 8)
            if learned {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(SummaryStyle.activity)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - Muscle load

/// Sets per muscle group this week on the two figures, then every recorded set by day.
struct MuscleLoadView: View {
    @State private var records: [RepSetRecord] = []

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        let sets = RepSetStore.setsPerMuscle(days: 7, records: records)
        let top = max(sets.values.max() ?? 0, 1)
        let ranked = sets.sorted { $0.value > $1.value }
        ScreenScaffold(title: "Muscle load") {
            SummaryCard(symbol: "figure.strengthtraining.traditional", title: "Sets per muscle",
                        trailing: "Last 7 days", accent: SummaryStyle.activity) {
                MuscleFigure(levels: sets.mapValues { $0 / top })
                    .frame(height: 260)
                    .padding(.top, 12)
                if ranked.isEmpty {
                    Text("Finish a set in the rep counter and it shows up here.")
                        .font(.system(size: 16))
                        .foregroundStyle(SummaryStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                ForEach(ranked, id: \.key) { entry in
                    Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                    HStack {
                        Text(MuscleGroups.title(entry.key))
                            .font(.system(size: 17))
                            .foregroundStyle(SummaryStyle.primary)
                        Spacer()
                        Text(entry.value.formatted(.number.precision(.fractionLength(0...1))))
                            .font(SummaryStyle.number(17, .regular))
                            .foregroundStyle(SummaryStyle.secondary)
                    }
                    .frame(height: 46)
                }
            }
            ForEach(days, id: \.day) { group in
                SummaryCard(symbol: "calendar", title: LocalizedStringKey(Self.dayFormatter.string(from: group.day)), accent: SummaryStyle.activity) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(SummaryStyle.rule).frame(height: 0.5) }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(SummaryStyle.primary)
                                    .lineLimit(1)
                                Text(MuscleGroups.title(item.muscle))
                                    .font(.system(size: 15))
                                    .foregroundStyle(SummaryStyle.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(item.summary)
                                .font(SummaryStyle.number(16, .regular))
                                .foregroundStyle(SummaryStyle.secondary)
                        }
                        .frame(minHeight: 56)
                    }
                }
            }
        }
        .onAppear { records = RepSetStore.all() }
    }

    private struct DayItem {
        let name: String
        let muscle: String
        let summary: String
    }

    /// The recorded sets grouped by day, newest day first; sets of one exercise on one day share a row.
    private var days: [(day: Date, items: [DayItem])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            let sets = (byDay[day] ?? []).sorted { $0.date < $1.date }
            var order: [String] = []
            var grouped: [String: [RepSetRecord]] = [:]
            for set in sets {
                let key = set.exerciseId.isEmpty ? set.name : set.exerciseId
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(set)
            }
            let items: [DayItem] = order.map { key in
                let group = grouped[key] ?? []
                let reps = group.map { String($0.reps) }.joined(separator: ", ")
                let weight = group.map(\.weightKg).max() ?? 0
                let text = weight > 0
                    ? "\(reps) × \(weight.formatted(.number.precision(.fractionLength(0...1)))) kg"
                    : reps
                return DayItem(name: group.first?.name ?? "", muscle: group.first?.muscle ?? "", summary: text)
            }
            return (day: day, items: items)
        }
    }
}

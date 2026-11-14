import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Exercise library

/// One exercise from the bundled list (free-exercise-db, public domain). The two photos of each
/// exercise are loaded from that project's repository when shown; nothing else leaves the phone.
struct LibraryExercise: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let muscle: String
    let equipment: String
    let category: String
    let images: [String]

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

// MARK: - Views

/// The exercise's two photos shown in turn, which reads as the movement.
struct ExerciseAnimation: View {
    let exercise: LibraryExercise

    var body: some View {
        let urls = exercise.imageURLs
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.9)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.9) % 2
            ZStack {
                ForEach(0..<min(urls.count, 2), id: \.self) { index in
                    AsyncImage(url: urls[index]) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        StrandPalette.surfaceInset
                    }
                    .opacity(urls.count < 2 || index == phase ? 1 : 0)
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Search the library and pick one exercise. Exercises the counter has already learned come first.
struct ExercisePickerView: View {
    @Binding var selection: LibraryExercise?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [LibraryExercise] {
        let learned = RepProfileStore.all()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = text.isEmpty
            ? ExerciseLibrary.all
            : ExerciseLibrary.all.filter { $0.name.lowercased().contains(text) || $0.muscle.contains(text) }
        let first = matching.filter { learned[$0.id] != nil }
        let rest = matching.filter { learned[$0.id] == nil }
        return first + rest
    }

    var body: some View {
        let learned = RepProfileStore.all()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose exercise")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
                Spacer()
                Button("Close") { dismiss() }
                    .foregroundStyle(SummaryStyle.tint)
            }
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StrandPalette.surfaceInset))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { exercise in
                        Button {
                            selection = exercise
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name)
                                        .font(.system(size: 16))
                                        .foregroundStyle(SummaryStyle.primary)
                                    Text(exercise.muscle.capitalized)
                                        .font(.system(size: 13))
                                        .foregroundStyle(SummaryStyle.secondary)
                                }
                                Spacer()
                                if learned[exercise.id] != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(SummaryStyle.tint)
                                }
                            }
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(18)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}

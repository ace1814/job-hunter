import ShortlistCore
import SwiftUI
import UniformTypeIdentifiers

/// Your master profile, resume and scoring model: what every job is judged against.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Draft()
    @State private var isPickingResume = false
    @State private var keyText = ""

    /// The form's text, with lists as comma-separated lines.
    private struct Draft: Equatable {
        var headline = ""
        var targetRoles = ""
        var seniority = ""
        var locations = ""
        var remotePreference = RemotePreference.any
        var minSalary = ""
        var mustHaves = ""
        var dealbreakers = ""
        var summary = ""
        var skills = ""

        init() {}

        init(_ profile: Profile) {
            headline = profile.headline
            targetRoles = profile.targetRoles.joined(separator: ", ")
            seniority = profile.seniority
            locations = profile.locations.joined(separator: ", ")
            remotePreference = profile.remotePreference
            minSalary = profile.minSalary
            mustHaves = profile.mustHaves.joined(separator: ", ")
            dealbreakers = profile.dealbreakers.joined(separator: ", ")
            summary = profile.masterResume.summary
            skills = profile.masterResume.skills.joined(separator: ", ")
        }

        func applied(to profile: Profile) -> Profile {
            var updated = profile
            updated.headline = headline
            updated.targetRoles = Self.list(targetRoles)
            updated.seniority = seniority
            updated.locations = Self.list(locations)
            updated.remotePreference = remotePreference
            updated.minSalary = minSalary
            updated.mustHaves = Self.list(mustHaves)
            updated.dealbreakers = Self.list(dealbreakers)
            updated.masterResume.summary = summary
            updated.masterResume.skills = Self.list(skills)
            return updated
        }

        private static func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        /// Starting answers for a brand new profile: the markets chosen when the app was planned.
        static var starter: Draft {
            var draft = Draft()
            draft.targetRoles = "Senior Product Designer, Product Manager"
            draft.seniority = "Senior"
            draft.locations = "India on-site or hybrid, global remote, US, EU"
            return draft
        }
    }

    private var isDirty: Bool { draft.applied(to: model.profile) != model.profile }

    var body: some View {
        Form {
            resumeSection
            targetSection
            scoringSection
            checkSection
        }
        .formStyle(.grouped)
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem {
                Button("Save") { model.save(draft.applied(to: model.profile)) }
                    .disabled(!isDirty)
                    .help("Saving changes means waiting jobs get scored again")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.profile) { old, new in
            // A resume import changed it underneath the form.
            guard old.masterResume != new.masterResume else { return }
            load()
            if new.targetRoles.isEmpty { model.save(draft.applied(to: new)) }
        }
        .fileImporter(isPresented: $isPickingResume, allowedContentTypes: [.pdf, .plainText]) { result in
            if case .success(let url) = result {
                Task { await model.importResume(from: url) }
            }
        }
    }

    private func load() {
        let profile = model.profile
        draft = Draft(profile)
        if profile.targetRoles.isEmpty && profile.locations.isEmpty {
            let starter = Draft.starter
            draft.targetRoles = starter.targetRoles
            draft.seniority = starter.seniority
            draft.locations = starter.locations
        }
    }

    private var resumeSection: some View {
        Section("Resume") {
            LabeledContent {
                Button("Import PDF or Text…") { isPickingResume = true }
                    .disabled(model.isImportingResume)
            } label: {
                if model.isImportingResume {
                    Text("Reading your resume…")
                } else {
                    Text(model.resumeMessage ?? "Your email and phone number stay on this Mac. The rest goes to \(model.scoring.modelName).")
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Headline", text: $draft.headline)
            TextField("Summary", text: $draft.summary, axis: .vertical).lineLimit(2...6)
            TextField("Skills", text: $draft.skills, axis: .vertical).lineLimit(1...4)
            ForEach(Array(model.profile.masterResume.experience.enumerated()), id: \.offset) { _, role in
                LabeledContent(role.title) {
                    Text("\(role.company) · \(role.start)–\(role.end ?? "now") · \(role.bullets.count) bullets")
                }
            }
        }
    }

    private var targetSection: some View {
        Section("What you're looking for") {
            TextField("Target roles", text: $draft.targetRoles, prompt: Text("Comma separated"))
            TextField("Seniority", text: $draft.seniority)
            TextField("Where you'll work", text: $draft.locations, prompt: Text("Comma separated"))
            Picker("Work style", selection: $draft.remotePreference) {
                Text("Any").tag(RemotePreference.any)
                Text("Hybrid or remote").tag(RemotePreference.hybridOrRemote)
                Text("Remote only").tag(RemotePreference.remoteOnly)
            }
            TextField("Minimum pay", text: $draft.minSalary)
            TextField("Must-haves", text: $draft.mustHaves, prompt: Text("Comma separated"))
            TextField("Dealbreakers", text: $draft.dealbreakers, prompt: Text("Comma separated"))
        }
    }

    private var scoringSection: some View {
        Section {
            Picker("Scoring with", selection: binding(\.provider)) {
                Text("OpenAI").tag(ScoringSettings.Provider.openAI)
                Text("Ollama, on this Mac").tag(ScoringSettings.Provider.ollama)
            }
            if model.scoring.provider == .openAI {
                TextField("Model", text: binding(\.openAIModel))
                if model.hasOpenAIKey {
                    LabeledContent("API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.seal").foregroundStyle(.green)
                            Button("Remove") { model.removeOpenAIKey() }
                        }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $keyText)
                        Button("Save") {
                            model.saveOpenAIKey(keyText)
                            keyText = ""
                        }
                        .disabled(keyText.isEmpty)
                    }
                }
            } else {
                TextField("Model", text: binding(\.ollamaModel))
            }
        } header: {
            Text("Scoring model")
        } footer: {
            Text(model.scoring.provider == .openAI
                 ? "Each job and your profile, without your name or contact details, go to OpenAI."
                 : "Nothing leaves this Mac. Needs Ollama running, and it's much slower.")
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<ScoringSettings, Value>) -> Binding<Value> {
        Binding {
            model.scoring[keyPath: path]
        } set: { value in
            var updated = model.scoring
            updated[keyPath: path] = value
            model.save(updated)
        }
    }

    private var checkSection: some View {
        Section {
            LabeledContent("\(model.labeledJobs) of \(ScoreCheck.suggestedLabels) jobs labeled") {
                Button(model.isCheckingModel ? "Checking…" : "Check \(model.scoring.modelName)") {
                    Task { await model.checkModel() }
                }
                .disabled(model.isCheckingModel || model.labeledJobs < 2)
            }
            if let message = model.checkMessage {
                Text(message).foregroundStyle(.red)
            }
            ForEach(model.scoreChecks) { result in
                LabeledContent(result.model) {
                    Text(describe(result)).monospacedDigit()
                }
            }
        } header: {
            Text("Model check")
        } footer: {
            Text("Label jobs in All Jobs, then see how often a model agrees with you. This doesn't change your saved scores.")
        }
    }

    private func describe(_ result: ScoreCheck.Result) -> String {
        var parts = ["\(Int((result.agreement * 100).rounded()))% agreement on \(result.labeled)"]
        if let yes = result.yesAverage, let no = result.noAverage {
            parts.append("yes \(Int(yes.rounded())), no \(Int(no.rounded()))")
        }
        parts.append(String(format: "%.0fs", result.seconds))
        return parts.joined(separator: " · ")
    }
}

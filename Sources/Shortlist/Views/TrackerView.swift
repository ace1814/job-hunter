import ShortlistCore
import SwiftUI

/// Every job you're following, wherever it came from, by stage. Anything due sits at the top.
struct TrackerView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var isAdding = false

    private func matches(_ item: JobListItem) -> Bool {
        search.isEmpty || item.job.title.localizedCaseInsensitiveContains(search)
            || item.job.companyName.localizedCaseInsensitiveContains(search)
    }

    private var due: [JobListItem] { model.dueJobs.filter(matches) }

    private func items(in stage: JobStatus) -> [JobListItem] {
        let dueIDs = Set(model.dueJobs.map(\.id))
        return model.tracked.filter { $0.job.status == stage && !dueIDs.contains($0.id) && matches($0) }
    }

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 320, idealWidth: 400)
            Group {
                if let item = model.tracked.first(where: { $0.id == model.trackerSelection }) {
                    JobDetail(item: item)
                } else {
                    ContentUnavailableView("Pick a job", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Tracker")
        .navigationSubtitle(model.tracked.isEmpty ? "" : "\(model.tracked.count) job\(model.tracked.count == 1 ? "" : "s")")
        .searchable(text: $search, prompt: "Search titles and companies")
        .toolbar {
            ToolbarItem {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Job", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("n")
                .help("Add a job from a link")
            }
        }
        .sheet(isPresented: $isAdding) { AddJobSheet() }
    }

    @ViewBuilder
    private var list: some View {
        @Bindable var model = model
        if model.tracked.isEmpty {
            ContentUnavailableView {
                Label("Nothing to track yet", systemImage: "checklist")
            } description: {
                Text("Add a job from a link, or press Save to Tracker on any job.")
            } actions: {
                Button("Add Job") { isAdding = true }
            }
        } else {
            List(selection: $model.trackerSelection) {
                if !due.isEmpty {
                    Section("Follow up") {
                        ForEach(due) { JobRow(item: $0) }
                    }
                }
                ForEach(JobStatus.tracked, id: \.self) { stage in
                    let jobs = items(in: stage)
                    if !jobs.isEmpty {
                        Section(stage.title) {
                            ForEach(jobs) { JobRow(item: $0) }
                        }
                    }
                }
            }
        }
    }
}

/// Paste a link and the rest fills itself in as far as the page allows. You can change all of it.
struct AddJobSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var new = Tracker.NewJob(url: "", title: "", company: "")
    @State private var reading: JobPage.Reading?
    @State private var problem: String?
    @State private var isReading = false
    @State private var hasApplied = false
    @State private var appliedOn = Date.now

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField("Job link", text: $link, prompt: Text("https://…"))
                        if isReading { ProgressView().controlSize(.small) }
                    }
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Title", text: $new.title)
                    TextField("Company", text: $new.company)
                    TextField("Location", text: $new.location)
                    Picker("Work", selection: $new.remotePolicy) {
                        ForEach(RemotePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("I've already applied", isOn: $hasApplied)
                    if hasApplied {
                        DatePicker("Applied on", selection: $appliedOn, in: ...Date.now, displayedComponents: .date)
                    }
                    TextField("Note", text: $new.note, axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Job") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(14)
        }
        .frame(width: 460, height: 500)
        .task(id: link) { await read() }
    }

    private var status: String? {
        if let problem { return problem }
        switch reading {
        case .known: return "Already in Shortlist from your feeds."
        case .board, .structured: return "Read from the posting."
        case .guess: return "Read from the page's title, so check these."
        default: return nil
        }
    }

    private var canAdd: Bool {
        JobPageReader.cleanURL(link) != nil && !new.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !new.company.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Runs shortly after the link stops changing, so a paste reads once and typing doesn't fetch
    /// half an address.
    private func read() async {
        guard JobPageReader.cleanURL(link) != nil else {
            reading = nil
            problem = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        isReading = true
        defer { isReading = false }
        let page = await model.readJobLink(link)
        guard !Task.isCancelled else { return }
        reading = page.reading
        problem = page.problem
        let note = new.note
        // What you've already typed stays.
        let (title, company, location) = (new.title, new.company, new.location)
        new = Tracker.NewJob(page: page)
        new.note = note
        if !title.isEmpty { new.title = title }
        if !company.isEmpty { new.company = company }
        if !location.isEmpty { new.location = location }
    }

    private func add() {
        new.url = JobPageReader.cleanURL(link)?.absoluteString ?? link
        new.appliedAt = hasApplied ? appliedOn : nil
        model.addJob(new)
        dismiss()
    }
}

extension JobStatus {
    var title: String {
        switch self {
        case .saved: "Saved"
        case .applied: "Applied"
        case .interviewing: "Interviewing"
        case .offer: "Offer"
        case .rejected: "Rejected"
        default: rawValue.capitalized
        }
    }
}

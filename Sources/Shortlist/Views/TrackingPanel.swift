import AppKit
import ShortlistCore
import SwiftUI

/// What you're keeping on a job you follow: its stage, reminders, notes and the people involved.
struct TrackingPanel: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.job.status != .saved { stageRow }
            RemindersSection(item: item)
            Divider()
            NotesSection(item: item)
            Divider()
            ContactsSection(item: item)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var stageRow: some View {
        HStack {
            Picker("Stage", selection: Binding {
                item.job.status
            } set: {
                model.setStage($0, for: item)
            }) {
                ForEach(JobStatus.tracked.filter { $0 != .saved }, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Spacer()
            if [.applied, .interviewing].contains(item.job.status) {
                Button("Interview Done") { model.interviewDone(item) }
                    .help("Moves this to Interviewing and reminds you to say thanks tomorrow")
            }
        }
    }
}

private struct RemindersSection: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem
    @State private var isAdding = false
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Reminders", systemImage: "bell").font(.headline)
                Spacer()
                Button("Add Reminder") { isAdding = true }
                    .controlSize(.small)
                    .popover(isPresented: $isAdding) { addForm }
            }
            let reminders = model.tracking.reminders[item.id] ?? []
            if reminders.isEmpty {
                Text("Nothing due.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(reminders) { ReminderRow(item: item, reminder: $0) }
            if let message = model.draftMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Remind me on", selection: $due, in: Date.now..., displayedComponents: .date)
            TextField("What for?", text: $note).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Add") {
                    model.addReminder(on: due, note: note, for: item)
                    note = ""
                    isAdding = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// One reminder, and the message for it once there's a draft. The buttons only open or copy the
/// message: you send it yourself.
private struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: JobListItem
    let reminder: Reminder
    @State private var subject = ""
    @State private var message = ""

    private var isWriting: Bool { reminder.id.map(model.drafting.contains) ?? false }
    private var recipient: JobContact? { model.tracking.recipient(for: item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.note.isEmpty ? reminder.kind.title : reminder.note).fontWeight(.medium)
                    Text(reminder.dueText).font(.caption)
                        .foregroundStyle(reminder.isDue() ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer()
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(reminder.hasDraft ? "Redo" : "Write Message") { write() }
                        .help("Sends the job and your notes to \(model.scoring.modelName). You read it before anything goes out.")
                }
                Button("Later") { model.snooze(reminder) }
                    .help("Moves this \(Reminders.snoozeDays) days on")
                Button("Done") { save(); model.finish(reminder) }
            }
            .controlSize(.small)

            if reminder.hasDraft {
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                TextEditor(text: $message)
                    .font(.callout)
                    .frame(height: 130)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: .rect(cornerRadius: 6))
                HStack {
                    Button("Copy") {
                        save()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    Button("Open in Gmail") {
                        save()
                        if let url = FollowUpMessage.gmailURL(to: recipient?.email ?? "", subject: subject, body: message) { openURL(url) }
                    }
                    .help("Opens it in Gmail ready to read and send")
                    Spacer()
                    Text(recipient.map { "To \($0.email)" } ?? "No email saved. Copy it for LinkedIn, or add a contact.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
        .onAppear(perform: load)
        .onChange(of: reminder.draftBody) { load() }
        .onChange(of: reminder.draftSubject) { load() }
        .onDisappear { save() }
    }

    private func load() {
        subject = reminder.draftSubject
        message = reminder.draftBody
    }

    private func save() {
        guard reminder.hasDraft, subject != reminder.draftSubject || message != reminder.draftBody else { return }
        model.saveDraft(of: reminder, subject: subject, body: message)
    }

    private func write() {
        Task { await model.writeMessage(for: reminder) }
    }
}

extension Reminder {
    var dueText: String {
        let left = daysLeft()
        switch left {
        case ..<(-1): return "\(-left) days overdue"
        case -1: return "Due yesterday"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due in \(left) days"
        }
    }

    /// Short enough for a job row.
    var shortDueText: String {
        let left = daysLeft()
        switch left {
        case ..<0: return "Overdue"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "In \(left)d"
        }
    }
}

private struct NotesSection: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Notes", systemImage: "note.text").font(.headline)
            HStack(alignment: .bottom) {
                TextField("Add a note", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    model.addNote(draft, for: item)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(model.tracking.notes[item.id] ?? []) { note in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.text).textSelection(.enabled)
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RemoveButton(help: "Delete this note") { model.remove(note) }
                }
                .font(.callout)
            }
        }
    }
}

private struct ContactsSection: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("People you're talking to", systemImage: "person.crop.circle").font(.headline)
            ForEach(model.tracking.contacts[item.id] ?? []) { contact in
                HStack {
                    Text(contact.name.isEmpty ? contact.email : contact.name).fontWeight(.medium)
                    if !contact.name.isEmpty { Text(contact.email).foregroundStyle(.secondary).textSelection(.enabled) }
                    Spacer()
                    RemoveButton(help: "Remove") { model.remove(contact) }
                }
                .font(.callout)
            }
            HStack {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                Button("Add") {
                    model.addContact(name: name, email: email, for: item)
                    (name, email) = ("", "")
                }
                .disabled(name.isEmpty && email.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

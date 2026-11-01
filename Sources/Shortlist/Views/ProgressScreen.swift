import ShortlistCore
import SwiftUI

/// How the search is going: your streak, the last two weeks, and what's become of each application.
struct ProgressScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(spacing: 28) {
                    stat("\(model.stats.currentStreak)", "day streak")
                    stat("\(model.stats.bestStreak)", "best streak")
                    stat("\(model.stats.totalApplied)", "applied")
                    stat("\(model.stats.interviewing)", "interviewing")
                    stat("\(model.stats.offers)", "offers")
                }
                .padding(.vertical, 4)
                RecentDays(days: model.stats.recentDays)
            } header: {
                Text("Last two weeks")
            } footer: {
                Text("A streak counts the days you reach your target.")
            }

            Section("Applications") {
                if model.appliedJobs.isEmpty {
                    Text("Jobs you mark as applied show up here.").foregroundStyle(.secondary)
                }
                ForEach(model.appliedJobs) { item in
                    ApplicationRow(item: item)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Progress")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 26, weight: .semibold).monospacedDigit())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct RecentDays: View {
    let days: [ProgressStats.Day]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                let share = day.target == 0 ? 0 : min(Double(day.submitted) / Double(day.target), 1)
                VStack(spacing: 4) {
                    Capsule()
                        .fill(share >= 1 ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .frame(height: max(4, 56 * share))
                        .frame(height: 56, alignment: .bottom)
                    Text(day.day.suffix(2)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.submitted) of \(day.target) on \(day.day)")
            }
        }
    }
}

private struct ApplicationRow: View {
    @Environment(AppModel.self) private var model
    let item: JobListItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.job.title)
                Text(item.job.companyName).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Stage", selection: Binding {
                item.job.status
            } set: {
                model.setStage($0, for: item)
            }) {
                Text("Applied").tag(JobStatus.applied)
                Text("Interviewing").tag(JobStatus.interviewing)
                Text("Offer").tag(JobStatus.offer)
                Text("Rejected").tag(JobStatus.rejected)
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

import ShortlistCore
import SwiftUI

/// The scoring strip: how many jobs are waiting, the button, progress, and the last run's result.
/// It sits above the job lists so it can't be missed, and hides when there's nothing to say.
struct ScoreBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScoring || model.pendingScores > 0 || model.scoringMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = model.scoringProgress {
                    running(progress)
                } else if model.pendingScores > 0 {
                    waiting
                }
                if let message = model.scoringMessage, !model.isScoring {
                    HStack(alignment: .top, spacing: 6) {
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Hide", systemImage: "xmark") { model.clearScoringMessage() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
        }
    }

    private var waiting: some View {
        HStack {
            Label("\(model.pendingScores) job\(model.pendingScores == 1 ? "" : "s") waiting for a score", systemImage: "sparkles")
                .fontWeight(.medium)
            Spacer()
            Button("Score Jobs") { model.scoreJobs() }
                .buttonStyle(.borderedProminent)
                .help("Score up to \(JobScorer.defaultLimit) jobs with \(model.scoring.modelName)")
        }
    }

    private func running(_ progress: (done: Int, total: Int)) -> some View {
        HStack(spacing: 10) {
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("\(progress.done) of \(progress.total)").font(.callout.monospacedDigit())
            } else {
                ProgressView().controlSize(.small)
                Text("Scoring…").font(.callout)
                Spacer()
            }
            Button("Stop") { model.stopScoring() }
                .help("Finished jobs keep their scores")
        }
    }
}

/// Where your OpenAI key goes. Used in setup and on the Profile screen.
struct OpenAIKeyField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        if model.hasOpenAIKey {
            HStack {
                Label("Key saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Remove") { model.removeOpenAIKey() }
            }
        } else {
            HStack {
                SecureField("Paste your OpenAI key here", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save Key", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
                Link("Get a key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
        }
    }

    private func save() {
        model.saveOpenAIKey(text)
        text = ""
    }
}

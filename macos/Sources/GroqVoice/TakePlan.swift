import Foundation

/// Which key started the take.
enum TakeKind: Equatable {
    case dictate
    case action(KeyAction)
}

/// What to do with a take once its words are known: the text to paste, or the
/// request for the language model and what happens when no model answers.
/// Deciding is pure — no network, no UI — so the routing rules can be tested.
struct TakePlan: Equatable {
    struct Request: Equatable {
        var system: String
        var user: String
        var temperature = 0.0
    }

    enum WithoutAnswer: Equatable {
        case pasteText          // the model was optional: `text` goes in as it is
        case fail(String)       // the model was the point: this error is shown
    }

    struct Result: Equatable {
        var text: String
        var kind: HistoryEntry.Kind
        /// What the model was given, when `text` is its answer.
        var original: String?
        /// Why the model's answer was not used, for the log.
        var note: String?
    }

    /// What the take becomes if the model answers (or if none is needed).
    var kind: HistoryEntry.Kind
    /// Pasted when no model is asked, or when it is optional and gave nothing.
    var text: String
    var request: Request?
    var withoutAnswer = WithoutAnswer.pasteText
    var original: String?
    /// Clean-up only: an answer much shorter or longer than the input is the
    /// model answering or elaborating instead of editing.
    var answerMustKeepLength = false
    var spokenFormatting = false

    static func make(transcript: String, selection: String?, take: TakeKind, cfg: Config,
                     snippets: Snippets, vocabularyPrompt: String) throws -> TakePlan {
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if case .action(let action) = take {
            if !action.isTranslate, isBlank(action.prompt) {
                throw AppError("The custom prompt for \(action.key.title) is empty — set it in Settings")
            }
            // With a selection the action targets it and speech is a side note;
            // otherwise the speech itself is the text to act on.
            let target = selection ?? transcript
            guard !isBlank(target) else { throw AppError("Nothing recognized") }
            var system = action.isTranslate
                ? TaskRouter.translateSystemPrompt(to: action.languageName)
                : TaskRouter.customActionSystemPrompt(action.prompt)
            var user = action.isTranslate ? target : TaskRouter.fenced(target)
            if selection != nil, !isBlank(transcript) {
                system += TaskRouter.spokenNoteRule
                user = TaskRouter.actionUserMessage(target: target, spoken: transcript)
            }
            return TakePlan(kind: action.isTranslate ? .translate : .prompt, text: "",
                            request: Request(system: system, user: user),
                            withoutAnswer: .fail("No language model for this key — configure one in Settings → Groq & LLM"),
                            original: target)
        }

        guard !isBlank(transcript) else { throw AppError("Nothing recognized") }
        let taskQuery = TaskRouter.taskQuery(from: transcript, keywords: cfg.taskKeywords,
                                             maxPosition: cfg.taskKeywordMaxWordPosition)

        if let selection {
            // An instruction about the selection, or its replacement — the model
            // decides. "задание: …" in front is fine too: drop the keyword.
            // Without the model the selection stays: pasting "сделай короче"
            // over the paragraph it was said about would destroy it.
            let user = TaskRouter.editSelectionUserMessage(selection: selection, spoken: taskQuery ?? transcript)
            return TakePlan(kind: .edit, text: transcript,
                            request: Request(system: TaskRouter.editSelectionSystemPrompt, user: user),
                            withoutAnswer: .fail("No language model answered — the selection was left as it is"),
                            original: selection)
        }
        if let expansion = snippets.expansion(for: transcript) {
            // The whole utterance is a snippet phrase: its text, no model.
            return TakePlan(kind: .snippet, text: expansion)
        }
        if let taskQuery {
            // Never paste the raw "задание …" transcript when no model can run it.
            let base = cfg.taskSystemPrompt.isEmpty ? TaskRouter.defaultSystemPrompt : cfg.taskSystemPrompt
            return TakePlan(kind: .task, text: "",
                            request: Request(system: base + snippets.systemPromptSection(), user: taskQuery, temperature: 0.3),
                            withoutAnswer: .fail("No language model available for task mode"),
                            original: transcript)
        }
        var plan = TakePlan(kind: .dictation, text: transcript, spokenFormatting: cfg.spokenFormatting)
        if cfg.cleanupTranscript, transcript.split(whereSeparator: \.isWhitespace).count >= 3 {
            plan.request = Request(system: TaskRouter.cleanupSystemPrompt(vocabulary: vocabularyPrompt), user: transcript)
            plan.original = transcript
            plan.answerMustKeepLength = true
        }
        return plan
    }

    /// The text to paste, given the model's answer (nil: none was asked, or no
    /// backend answered).
    func result(answer: String?) throws -> Result {
        var out = Result(text: text, kind: request == nil ? kind : .dictation)
        if request != nil {
            let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ratio = Double(answer.count) / Double(max(1, text.count))
            if answer.isEmpty {
                if case .fail(let message) = withoutAnswer { throw AppError(message) }
                out.note = "\(kind.rawValue): no LLM answer — using the transcript"
            } else if answerMustKeepLength, !(0.5...1.6).contains(ratio) {
                out.note = String(format: "clean-up rejected (length ratio %.2f) — using the transcript", ratio)
            } else {
                out = Result(text: answer, kind: kind, original: original)
            }
        }
        if spokenFormatting, out.kind == .dictation { out.text = SpokenFormatting.apply(out.text) }
        return out
    }
}

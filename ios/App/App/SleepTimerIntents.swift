//
//  SleepTimerIntents.swift
//  App
//
//  Voice control for the sleep timer via App Intents ("Hey Siri, set an Audiobookshelf
//  sleep timer for 30 minutes"). SiriKit's media domain has no sleep-timer intent, so
//  these ship as zero-setup App Shortcuts instead: every phrase must name the app, and
//  perform() runs in-process -- in the background if the app isn't frontmost, after a
//  background launch if it isn't running at all.
//
//  Isolation: this file plus a one-line activation call in SiriMediaContext.initialize()
//  is the entire feature. The player is reached only through the PlayerHandler statics
//  and observed only through the PlayerEvents notifications the webview mirrors, which
//  is also why the webview's timer chip stays in sync with voice changes for free.
//

import Foundation
import AppIntents
import MediaPlayer
import SwiftUI

// MARK: - Armed-timer bookkeeping (reset support)

/// Remembers what the user last asked the sleep timer for, because the player does not:
/// AudioPlayer decrements sleepTimeRemaining in place and never stores the requested
/// duration, so "reset the sleep timer" is unanswerable from player state alone.
///
/// Timers armed by voice record their mode directly (expectArming/confirmArming).
/// Timers armed from the webview are caught by observing PlayerEvents.sleepSet and
/// reading the freshly-armed remaining time back off PlayerHandler -- the notification
/// itself carries no payload. All state is main-thread-confined.
@available(iOS 17.0, *)
final class SleepTimerVoiceState {

    /// A countdown timer whose remaining time happens to land within this many seconds
    /// (rate-adjusted) of the current chapter's end is indistinguishable from a chapter
    /// timer. Wide enough to absorb the 1 Hz countdown tick plus the hop from the
    /// posting thread to main; a coincidental countdown inside it is rare enough that
    /// misclassifying the reset mode is an acceptable worst case.
    private static let chapterDetectionTolerance: Double = 3.0

    enum ArmedMode {
        case countdown(seconds: Double)
        case chapter
    }

    static let shared = SleepTimerVoiceState()

    /// Called from SiriMediaContext.initialize() so the observers exist before the
    /// first webview-armed timer, not lazily on the first voice request -- otherwise
    /// "reset" could not know the original duration of a timer set by hand in the app.
    static func activate() {
        _ = shared
        // Re-assert App Shortcut registration on every launch. Static metadata should
        // make this redundant, but the system's index can drop the shortcuts after
        // reinstall churn (observed on an iOS 27 beta: Shortcuts app suddenly empty
        // with a fully valid Metadata.appintents in the bundle); this is the
        // documented way to force a re-publish.
        AbsShortcuts.updateAppShortcutParameters()
    }

    /// What an intent is about to arm; consumed by the sleepSet observation it
    /// triggers. Never outlives its perform() call: the arming APIs post sleepSet
    /// synchronously on the calling (main) thread, so confirmArming() runs after the
    /// consumption or not at all.
    private var pendingMode: ArmedMode?

    /// The last arming the user asked for. Survives the timer ending or being
    /// cancelled, which is what lets "reset the sleep timer" re-arm afterwards.
    private(set) var lastArmedMode: ArmedMode?

    /// Distinguishes a fresh arming from increase/decrease adjustments, which post the
    /// same sleepSet notification but must not overwrite the recorded original ask.
    private var timerRunning = false

    private var observers: [NSObjectProtocol] = []

    /// Notification order is captured at post time (under this lock) and re-checked on
    /// main, because delivery order isn't post order: a sleepEnded posted from a
    /// background queue (natural expiry, webview cancel) can reach main after a voice
    /// arming that ran inline there, and would mark the new live timer as not running.
    private let sequenceLock = NSLock()
    private var lastPostedSequence = 0
    /// Main-thread-only, like the rest of the state.
    private var lastProcessedSequence = 0

    private init() {
        // queue: nil runs the blocks synchronously on the posting thread (documented,
        // unlike the delivery timing of queue: .main), which is what lets deliver()
        // stamp true post order before any hop.
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name(PlayerEvents.sleepSet.rawValue), object: nil, queue: nil) { [weak self] _ in
            self?.deliver { $0.onSleepSet() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name(PlayerEvents.sleepEnded.rawValue), object: nil, queue: nil) { [weak self] _ in
            self?.deliver { $0.onSleepEnded() }
        })
    }

    /// Runs the handler on main -- inline when already there, so voice armings observe
    /// their own events mid-perform() -- and drops any event that reaches main after a
    /// later-posted event has been processed: it describes a timer that no longer
    /// exists.
    private func deliver(_ handler: @escaping (SleepTimerVoiceState) -> Void) {
        sequenceLock.lock()
        lastPostedSequence += 1
        let sequence = lastPostedSequence
        sequenceLock.unlock()

        let process = { [weak self] in
            guard let self = self else { return }
            guard sequence > self.lastProcessedSequence else { return }
            self.lastProcessedSequence = sequence
            handler(self)
        }
        if Thread.isMainThread {
            process()
        } else {
            DispatchQueue.main.async(execute: process)
        }
    }

    /// Record what the calling intent is about to arm. The next sleepSet takes it as
    /// authoritative, bypassing detection -- detection cannot see, for example, that a
    /// countdown was chosen to coincide with a chapter boundary.
    func expectArming(_ mode: ArmedMode) {
        pendingMode = mode
    }

    /// True when the arming this intent just requested was actually observed. The
    /// PlayerHandler mutators are silently nil-guarded and setChapterSleepTimer bails
    /// on several guards without posting, so a still-pending record means the call did
    /// nothing and the intent should not claim success.
    func confirmArming() -> Bool {
        if pendingMode == nil { return true }
        pendingMode = nil
        return false
    }

    private func onSleepSet() {
        if let pending = pendingMode {
            lastArmedMode = pending
            pendingMode = nil
        } else if !timerRunning {
            // A fresh arming from the webview. setSleepTimer/setChapterSleepTimer both
            // removed any prior timer first (posting sleepEnded, so timerRunning is
            // already false again) and the new remaining time is readable by now.
            // Except: a 1 Hz tick that read its isSleepTimerSet before a cancel landed
            // but stamped after it arrives here with the timer already gone again --
            // it carries no information, and recording it would wipe the remembered
            // ask that "reset" needs.
            guard let detected = detectArmedMode() else { return }
            lastArmedMode = detected
        }
        // else: increase/decrease adjusting a running timer; keep the original ask.
        timerRunning = true
    }

    private func onSleepEnded() {
        // Keep lastArmedMode: it is exactly what "reset" needs after expiry or cancel.
        timerRunning = false
    }

    /// Classifies a freshly-armed timer nothing voice-side asked for. Chapter timers
    /// are recognizable because their remaining time, scaled by the playback rate,
    /// lands on the current chapter's end; anything else is a countdown.
    private func detectArmedMode() -> ArmedMode? {
        guard let remaining = PlayerHandler.getSleepTimeRemaining() else { return nil }

        if let currentTime = PlayerHandler.getCurrentTime(),
           let chapterEnd = PlayerHandler.getPlaybackSession()?.getCurrentChapter(at: currentTime)?.end {
            // Same convention as getSleepTimeRemaining: the live rate when playing,
            // 1.0 while paused (Now Playing mirrors rateManager.rate, 0 when paused).
            let liveRate = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0
            let rate = liveRate > 0 ? liveRate : 1.0
            if abs(remaining * rate - (chapterEnd - currentTime)) <= Self.chapterDetectionTolerance {
                return .chapter
            }
        }
        return .countdown(seconds: remaining)
    }
}

// MARK: - Duration choices

/// The durations Siri can match inside a spoken phrase. Parameters embedded in App
/// Shortcut phrases must be enumerable at build time, so arbitrary durations ("37
/// minutes") are not matchable -- a bare "set a sleep timer" prompts with these.
@available(iOS 17.0, *)
enum SleepTimerDuration: Int, AppEnum {
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case fortyFiveMinutes = 45
    case oneHour = 60
    /// Arms the player's chapter sleep timer (stop at the current chapter's end)
    /// instead of a countdown; the raw value is unused for this case.
    case endOfChapter = 0

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer Duration")

    static var caseDisplayRepresentations: [SleepTimerDuration: DisplayRepresentation] = [
        .fiveMinutes: "5 minutes",
        .tenMinutes: "10 minutes",
        .fifteenMinutes: "15 minutes",
        .thirtyMinutes: "30 minutes",
        .fortyFiveMinutes: "45 minutes",
        .oneHour: DisplayRepresentation(title: "1 hour", synonyms: ["an hour", "one hour", "60 minutes"]),
        .endOfChapter: DisplayRepresentation(title: "End of chapter", synonyms: ["the end of the chapter", "the end of this chapter", "this chapter ends"]),
    ]

    var seconds: Double { Double(rawValue) * 60 }

    var spokenName: String {
        switch self {
        case .oneHour: return "1 hour"
        case .endOfChapter: return "the end of the current chapter"
        default: return "\(rawValue) minutes"
        }
    }
}

// MARK: - Shared helpers

@available(iOS 17.0, *)
private enum ChapterArmOutcome {
    case armed
    /// No chapter metadata at the current position (chapterless books, most podcasts).
    case noChapter
    /// The player rejected the arming -- e.g. the chapter's end lies beyond the current
    /// audio track's end in a multi-file book, a guard setChapterSleepTimer enforces.
    case failed
}

@available(iOS 17.0, *)
@MainActor
private func armChapterSleepTimer() -> ChapterArmOutcome {
    guard let currentTime = PlayerHandler.getCurrentTime(),
          let session = PlayerHandler.getPlaybackSession(),
          let chapter = session.getCurrentChapter(at: currentTime),
          chapter.end > currentTime else {
        return .noChapter
    }
    // setChapterSleepTimer destroys any running timer BEFORE the guards that can make
    // it bail half-armed (stopAt set, no boundary observer ever scheduled), so a
    // request it would reject -- the chapter ending past the current audio file in a
    // multi-file book -- must be caught here first, keeping whatever timer is running
    // alive instead of trading it for nothing.
    let currentTrack = session.audioTracks.first { track in
        guard let start = track.startOffset, let end = track.endOffset else { return false }
        return start <= currentTime && currentTime < end
    }
    guard let trackEnd = currentTrack?.endOffset, trackEnd >= chapter.end else {
        return .failed
    }
    SleepTimerVoiceState.shared.expectArming(.chapter)
    PlayerHandler.setChapterSleepTime(stopAt: chapter.end)
    if SleepTimerVoiceState.shared.confirmArming() {
        return .armed
    }
    // Any silent bailout this side didn't predict still half-arms the player; clear
    // the zombie so Check and the webview chip don't report a countdown that will
    // never actually pause playback.
    PlayerHandler.cancelSleepTime()
    return .failed
}

/// Durations restored by "reset" can come from the webview, which allows values the
/// voice enum does not, so speak whatever is actually recorded.
private func spokenDuration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "under a minute" }
    if minutes == 1 { return "1 minute" }
    if minutes == 60 { return "1 hour" }
    return "\(minutes) minutes"
}

/// Compact remaining-time text for the snippet card: "29 min", "1 hr 5 min".
private func cardTimeText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
    }
    return minutes >= 1 ? "\(minutes) min" : "Under a minute"
}

/// The visual result Siri shows alongside (or, on builds where Siri stays silent,
/// instead of) the spoken dialog. Rendered as a static snapshot inside the Siri
/// overlay, so it must be self-contained and non-interactive.
@available(iOS 17.0, *)
private struct SleepTimerCard: View {
    /// Warm gold from the app icon, so the card reads as Audiobookshelf inside the
    /// otherwise app-less Siri overlay.
    private static let accent = Color(red: 0.91, green: 0.68, blue: 0.25)

    let icon: String
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let detail = detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

// MARK: - Intents

@available(iOS 17.0, *)
struct CheckSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Sleep Timer"
    static var description = IntentDescription("Says how much time is left on the sleep timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let remaining = PlayerHandler.getSleepTimeRemaining() else {
            return .result(dialog: "No sleep timer is running.",
                           view: SleepTimerCard(icon: "moon.zzz", title: "No sleep timer running"))
        }
        let card = SleepTimerCard(icon: "moon.zzz.fill", title: "\(cardTimeText(remaining)) left", detail: "Sleep timer")
        if remaining < 60 {
            return .result(dialog: "Less than a minute is left on the sleep timer.", view: card)
        }
        let minutes = Int((remaining / 60).rounded())
        if minutes == 1 {
            return .result(dialog: "About 1 minute is left on the sleep timer.", view: card)
        }
        return .result(dialog: "About \(minutes) minutes are left on the sleep timer.", view: card)
    }
}

@available(iOS 17.0, *)
struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Starts a sleep timer for the current audiobook or podcast.")

    @Parameter(title: "Duration", requestValueDialog: "For how long?")
    var duration: SleepTimerDuration

    static var parameterSummary: some ParameterSummary {
        Summary("Set a sleep timer for \(\.$duration)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard PlayerHandler.getCurrentTime() != nil else {
            return .result(dialog: "Nothing is playing right now.",
                           view: SleepTimerCard(icon: "play.slash", title: "Nothing is playing"))
        }
        if duration == .endOfChapter {
            switch armChapterSleepTimer() {
            case .armed:
                return .result(dialog: "Sleep timer set to the end of the current chapter.",
                               view: SleepTimerCard(icon: "moon.zzz.fill", title: "Until end of chapter", detail: "Sleep timer set"))
            case .noChapter:
                return .result(dialog: "This title doesn't have chapter markers. Try a timed sleep timer instead.",
                               view: SleepTimerCard(icon: "book.closed", title: "No chapter markers", detail: "Try a timed sleep timer"))
            case .failed:
                return .result(dialog: "I couldn't set a chapter sleep timer here. Try a timed sleep timer instead.",
                               view: SleepTimerCard(icon: "exclamationmark.triangle", title: "Couldn't set chapter timer", detail: "Try a timed sleep timer"))
            }
        }
        SleepTimerVoiceState.shared.expectArming(.countdown(seconds: duration.seconds))
        PlayerHandler.setSleepTime(secondsUntilSleep: duration.seconds)
        guard SleepTimerVoiceState.shared.confirmArming() else {
            return .result(dialog: "I couldn't set the sleep timer.",
                           view: SleepTimerCard(icon: "exclamationmark.triangle", title: "Couldn't set the sleep timer"))
        }
        return .result(dialog: "Sleep timer set for \(duration.spokenName).",
                       view: SleepTimerCard(icon: "moon.zzz.fill", title: duration.spokenName, detail: "Sleep timer set"))
    }
}

@available(iOS 17.0, *)
struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Sleep Timer"
    static var description = IntentDescription("Turns off the running sleep timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard PlayerHandler.getSleepTimeRemaining() != nil else {
            return .result(dialog: "There's no sleep timer running.",
                           view: SleepTimerCard(icon: "moon.zzz", title: "No sleep timer running"))
        }
        PlayerHandler.cancelSleepTime()
        return .result(dialog: "Sleep timer off.",
                       view: SleepTimerCard(icon: "moon.zzz", title: "Sleep timer off"))
    }
}

@available(iOS 17.0, *)
struct ResetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Reset Sleep Timer"
    static var description = IntentDescription("Restarts the sleep timer with its original duration.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard PlayerHandler.getCurrentTime() != nil else {
            return .result(dialog: "Nothing is playing right now.",
                           view: SleepTimerCard(icon: "play.slash", title: "Nothing is playing"))
        }
        guard let mode = SleepTimerVoiceState.shared.lastArmedMode else {
            return .result(dialog: "There's no recent sleep timer to reset.",
                           view: SleepTimerCard(icon: "moon.zzz", title: "No recent sleep timer", detail: "Nothing to reset"))
        }
        switch mode {
        case .chapter:
            switch armChapterSleepTimer() {
            case .armed:
                return .result(dialog: "Sleep timer reset to the end of the current chapter.",
                               view: SleepTimerCard(icon: "moon.zzz.fill", title: "Until end of chapter", detail: "Sleep timer reset"))
            case .noChapter, .failed:
                return .result(dialog: "I couldn't reset the chapter sleep timer here.",
                               view: SleepTimerCard(icon: "exclamationmark.triangle", title: "Couldn't reset chapter timer"))
            }
        case .countdown(let seconds):
            SleepTimerVoiceState.shared.expectArming(.countdown(seconds: seconds))
            PlayerHandler.setSleepTime(secondsUntilSleep: seconds)
            guard SleepTimerVoiceState.shared.confirmArming() else {
                return .result(dialog: "I couldn't reset the sleep timer.",
                               view: SleepTimerCard(icon: "exclamationmark.triangle", title: "Couldn't reset the sleep timer"))
            }
            return .result(dialog: "Sleep timer reset to \(spokenDuration(seconds)).",
                           view: SleepTimerCard(icon: "moon.zzz.fill", title: spokenDuration(seconds), detail: "Sleep timer reset"))
        }
    }
}

// MARK: - Shortcut phrases

// LOCALIZATION -- deliberately English-only, and NOT wired into strings/*.json.
// Everything Siri-facing in this file is currently English. This cannot reuse the
// webview translation system (strings/*.json): the phrases below are BUILD-TIME
// metadata the compiler extracts into Metadata.appintents, and the dialogs/cards
// resolve natively via LocalizedStringResource -- in-process, possibly before the
// webview exists (Siri background-launches the app). Siri only matches phrases in
// the language Siri itself is set to, so until localized, non-English Siri cannot
// trigger these at all (the INPlayMediaIntent play path is system-domain and needs
// no translation). Missing translations fall back per-key to English, exactly like
// the webview's i18n. A translations PR needs:
//   1. Phrase translations as per-locale <lang>.lproj/AppShortcuts.strings files
//      ("<English phrase with ${placeholders}>" = "<translated phrase>";). The
//      modern AppShortcuts.xcstrings catalog is NOT an option: the metadata
//      processor rejects it below a 17.0 DEPLOYMENT target (tested; the provider's
//      @available(iOS 17.0) does not satisfy it), and this app ships at 14.0. Only
//      translated locales need a file -- English comes from the code below. These
//      must be DESIGNED per language, not literally translated: each language has
//      its own version of the Clock-app grammar collision ("set a(n) X sleep timer
//      for N minutes" parses as a valid named Clock timer), so each locale needs
//      phrase shapes Clock's grammar cannot claim, like the English ones below.
//   2. Localizable.xcstrings (this directory) -- already contains the full English
//      key inventory: dialogs, intent titles/descriptions, parameter strings, and
//      SleepTimerDuration display names + synonyms. Translators add languages
//      there; no code changes needed for any of it.
//   3. A small code pass this catalog cannot cover: SleepTimerCard's title/detail
//      are plain Strings (Text(String) renders verbatim, bypassing localization),
//      and spokenName/spokenDuration/cardTimeText compose English words in code.
//      Wrap the card strings in String(localized:) and move duration text to
//      DateComponentsFormatter, which localizes for free.
// The community pipeline behind strings/*.json is the right group of people --
// just the wrong file format and delivery mechanism.

/// Zero-setup Siri phrases. Every phrase must embed \(.applicationName); the
/// INAlternativeAppNames in Info.plist ("audio book shelf" and friends) substitute
/// here too. Without the app name, "set a sleep timer for 30 minutes" belongs to the
/// Clock app -- and even WITH it, "set a(n) X sleep timer for N minutes" parses as a
/// valid Clock command for a named timer, so Siri disambiguates. Each shortcut
/// therefore leads with a shape Clock's grammar cannot claim (app name first, "in
/// \(.applicationName)", "stop X in N minutes") alongside the natural-but-ambiguous
/// wordings.
@available(iOS 17.0, *)
struct AbsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckSleepTimerIntent(), phrases: [
            "How long is left on the \(.applicationName) sleep timer",
            "How much time is left on the \(.applicationName) sleep timer",
            "How long is the \(.applicationName) sleep timer",
            "How much longer will \(.applicationName) play",
            "Check the sleep timer in \(.applicationName)",
            "Check the \(.applicationName) sleep timer",
        ],
        shortTitle: "Check Sleep Timer",
        systemImageName: "timer")
        AppShortcut(intent: SetSleepTimerIntent(), phrases: [
            "Set a sleep timer in \(.applicationName)",
            "Set a sleep timer in \(.applicationName) for \(\.$duration)",
            "\(.applicationName) sleep timer for \(\.$duration)",
            "Stop \(.applicationName) in \(\.$duration)",
            "Stop playing \(.applicationName) in \(\.$duration)",
            "Set a \(.applicationName) sleep timer",
            "Set an \(.applicationName) sleep timer",
            "Set a \(.applicationName) sleep timer for \(\.$duration)",
            "Set an \(.applicationName) sleep timer for \(\.$duration)",
        ],
        shortTitle: "Set Sleep Timer",
        systemImageName: "moon.zzz.fill")
        AppShortcut(intent: CancelSleepTimerIntent(), phrases: [
            "Cancel the sleep timer in \(.applicationName)",
            "Turn off the sleep timer in \(.applicationName)",
            "Cancel the \(.applicationName) sleep timer",
            "Stop the \(.applicationName) sleep timer",
            "Turn off the \(.applicationName) sleep timer",
        ],
        shortTitle: "Cancel Sleep Timer",
        systemImageName: "moon.zzz")
        AppShortcut(intent: ResetSleepTimerIntent(), phrases: [
            "Reset the sleep timer in \(.applicationName)",
            "Restart the sleep timer in \(.applicationName)",
            "Reset the \(.applicationName) sleep timer",
            "Restart the \(.applicationName) sleep timer",
        ],
        shortTitle: "Reset Sleep Timer",
        systemImageName: "arrow.counterclockwise")
    }
}

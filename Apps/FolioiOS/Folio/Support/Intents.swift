import AppIntents
import FolioCore

// Siri and Shortcuts. They also power automations: "When my AirPods
// connect, play my Daily Mix", "When my alarm stops, play the headlines".

/// Plays the Daily Mix without opening Folio.
struct PlayDailyMixIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play Daily Mix" }
    static var description: IntentDescription { IntentDescription("Plays a mix of your unread stories, read aloud.") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await AppModel.shared
        await model.start()
        let playing = await model.listen.playDailyMix()
        let message: IntentDialog = playing ? "Here's your Daily Mix." : "There's nothing unread to play right now."
        return .result(dialog: message)
    }
}

/// The news in a few minutes: each story as two sentences.
struct PlayHeadlinesIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play Headlines" }
    static var description: IntentDescription { IntentDescription("Reads your newest stories as short headlines.") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await AppModel.shared
        await model.start()
        let playing = await model.listen.playHeadlines()
        let message: IntentDialog = playing ? "Here are your headlines." : "There's nothing unread to play right now."
        return .result(dialog: message)
    }
}

/// How much is unread, and the latest stories.
struct WhatsNewIntent: AppIntent {
    static var title: LocalizedStringResource { "What's New" }
    static var description: IntentDescription { IntentDescription("Tells you how many stories are unread and names the latest ones.") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = await AppModel.shared
        await model.start()
        let latest = await model.whatsNew()
        return .result(dialog: IntentDialog(stringLiteral: latest))
    }
}

struct FolioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayDailyMixIntent(),
                    phrases: ["Play my Daily Mix in \(.applicationName)", "Play \(.applicationName) radio",
                              "Start my \(.applicationName) Daily Mix"],
                    shortTitle: "Daily Mix", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: PlayHeadlinesIntent(),
                    phrases: ["Play the headlines in \(.applicationName)", "\(.applicationName) headlines"],
                    shortTitle: "Headlines", systemImageName: "newspaper")
        AppShortcut(intent: WhatsNewIntent(),
                    phrases: ["What's new in \(.applicationName)", "Catch me up with \(.applicationName)"],
                    shortTitle: "What's New", systemImageName: "text.badge.star")
    }
}

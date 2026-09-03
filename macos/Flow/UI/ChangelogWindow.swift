import AppKit
import SwiftUI

struct ChangelogEntry: Identifiable, Equatable {
    let version: String
    var bullets: [String]

    var id: String { version }

    /// False for placeholders like "Unreleased".
    var isVersionNumber: Bool {
        !version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." }
    }
}

enum ChangelogParser {
    static func bundleMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Entries listed above the previously seen version in the changelog,
    /// which is authored newest first. If the previous version isn't in the
    /// file, returns nothing so unknown histories stay silent.
    static func entries(releasedAfter version: String?, in markdown: String?) -> [ChangelogEntry] {
        guard let markdown, let version else { return [] }
        let previous = version.unprefixedVersion
        var collected: [ChangelogEntry] = []
        for entry in parse(markdown) {
            if entry.version == previous { return collected }
            collected.append(entry)
        }
        return []
    }

    static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var current: ChangelogEntry?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if let current { entries.append(current) }
                let heading = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let raw = heading.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "(" }).first
                current = ChangelogEntry(version: (raw?.trimmingCharacters(in: .whitespaces) ?? "").unprefixedVersion, bullets: [])
            } else if trimmed.hasPrefix("- "), current != nil {
                current?.bullets.append(String(trimmed.dropFirst(2)))
            }
        }
        if let current { entries.append(current) }
        return entries.filter { !$0.version.isEmpty }
    }
}

private extension String {
    /// Strips a leading "v" so headings like "v0.5" and tags compare cleanly.
    var unprefixedVersion: String {
        hasPrefix("v") || hasPrefix("V") ? String(dropFirst()) : self
    }
}

@MainActor
final class ChangelogWindowController {
    private static let lastSeenVersionKey = "io.github.jdreioe.flow.lastSeenVersion"

    private let window: NSWindow

    init(entries: [ChangelogEntry]) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = L10n.string("What's New in Flow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChangelogView(entries: entries))
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the changelog on the first launch of a new version and records it.
    /// Fresh installs have no recorded previous version, so they stay silent.
    static func presentAfterUpdate() {
        let defaults = UserDefaults.standard
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        defer { defaults.set(currentVersion, forKey: lastSeenVersionKey) }
        guard let previous = defaults.string(forKey: lastSeenVersionKey),
              previous != currentVersion else { return }
        let newEntries = ChangelogParser.entries(
            releasedAfter: previous,
            in: ChangelogParser.bundleMarkdown()
        )
        guard !newEntries.isEmpty else { return }
        ChangelogWindowController(entries: newEntries).show()
    }

    static func showAll() {
        let entries = ChangelogParser.parse(ChangelogParser.bundleMarkdown() ?? "")
        guard !entries.isEmpty else { return }
        ChangelogWindowController(entries: entries).show()
    }
}

struct ChangelogView: View {
    let entries: [ChangelogEntry]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.isVersionNumber
                            ? L10n.format("Version %@", entry.version)
                            : entry.version)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(entry.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 4))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 7)
                                    Text(bullet)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

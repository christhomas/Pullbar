import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private var token: String?
    private var inbox: Inbox?
    private var lastError: Error?
    private var isRefreshing = false
    private var menuIsOpen = false

    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull requests")
            button.imagePosition = .imageLeading
            button.title = "…"
            button.toolTip = "pullbar — loading"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        Task { await bootstrapToken() }
    }

    private func bootstrapToken() async {
        if let stored = Keychain.readToken() {
            token = stored
        } else if let fromGh = await TokenProvider.fromGhCLI() {
            token = fromGh
        } else if let entered = TokenProvider.prompt() {
            token = entered
            try? Keychain.writeToken(entered)
        }
        if token == nil {
            lastError = GitHubError.noToken
            render()
        }
        scheduleTimer()
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.shared.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 10
    }

    // MARK: - Data

    func refresh() {
        guard !isRefreshing, let token else { return }
        isRefreshing = true
        let service = InboxService(client: GitHubClient(token: token))
        let window = Settings.shared.updatedWindow
        Task {
            do {
                let result = try await service.fetch(window: window)
                self.inbox = result
                self.lastError = nil
            } catch {
                self.lastError = error
            }
            self.isRefreshing = false
            self.render()
        }
    }

    // MARK: - Status item

    private func render() {
        guard let button = statusItem.button else { return }
        if let inbox {
            let mine = inbox.count(.needsYourReview)
            let teams = inbox.count(.needsTeamsReview)
            let action = inbox.count(.needsAction)
            var title = mine > 0 || teams > 0 ? "\(mine)" : ""
            if teams > 0 { title += "+\(teams)" }
            if action > 0 { title += (title.isEmpty ? "" : " ") + "⚠︎\(action)" }
            button.title = title
            button.toolTip = InboxSection.allCases
                .map { "\($0.title): \(inbox.count($0))" }
                .joined(separator: "\n")
            if lastError != nil {
                button.title = (title.isEmpty ? "" : title + " ") + "!"
            }
        } else if lastError != nil {
            button.title = "!"
            button.toolTip = lastError?.localizedDescription
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(titleItem(info: Bundle.main.infoDictionary))
        menu.addItem(.separator())

        if let error = lastError {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = twoLines(
                "Could not load the inbox",
                NSAttributedString(string: error.localizedDescription, attributes: secondaryAttributes())
            )
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(makeItem("Set GitHub token…", #selector(setToken)))
            menu.addItem(.separator())
        }

        for section in InboxSection.allCases {
            let prs = inbox?.pullRequests(in: section) ?? []
            menu.addItem(sectionHeader(section.title, count: inbox == nil ? nil : prs.count))
            if prs.isEmpty {
                let empty = NSMenuItem(title: inbox == nil ? "Loading…" : section.emptyText, action: nil, keyEquivalent: "")
                empty.isEnabled = false
                empty.indentationLevel = 1
                menu.addItem(empty)
            }
            for pr in prs {
                menu.addItem(pullRequestItem(pr))
            }
            menu.addItem(.separator())
        }

        menu.addItem(makeItem("Open inbox on GitHub", #selector(openInbox), key: "o"))
        let refreshItem = makeItem("Refresh now", #selector(refreshNow), key: "r")
        if let inbox {
            let when = relative.localizedString(for: inbox.fetchedAt, relativeTo: Date())
            refreshItem.attributedTitle = twoLines(
                "Refresh now",
                NSAttributedString(
                    string: "Updated \(when)" + (inbox.viewerLogin.isEmpty ? "" : " · signed in as \(inbox.viewerLogin)"),
                    attributes: secondaryAttributes()
                )
            )
        }
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(updatedWindowMenu())
        menu.addItem(refreshIntervalMenu())
        menu.addItem(launchAtLoginItem())
        menu.addItem(makeItem("Set GitHub token…", #selector(setToken)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit pullbar", #selector(quit), key: "q"))
    }

    private func sectionHeader(_ title: String, count: Int?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        if let count {
            text.append(NSAttributedString(
                string: "  \(count)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: count > 0 ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ]
            ))
        }
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    private func pullRequestItem(_ pr: PullRequest) -> NSMenuItem {
        let item = NSMenuItem(title: pr.title, action: #selector(openPullRequest(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pr.url
        item.indentationLevel = 1
        item.toolTip = "\(pr.repository)#\(pr.number)\n\(pr.title)\n\nClick to open on GitHub"

        let symbolColor: NSColor = pr.isDraft ? .secondaryLabelColor : NSColor.systemGreen
        item.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [symbolColor]))

        let meta = NSMutableAttributedString(
            string: "\(pr.repository)#\(pr.number) · \(pr.author) · updated \(relative.localizedString(for: pr.updatedAt, relativeTo: Date()))    ",
            attributes: secondaryAttributes()
        )

        let statusColor: NSColor
        if pr.isDraft {
            statusColor = .secondaryLabelColor
        } else {
            switch pr.reviewDecision {
            case .approved: statusColor = .systemGreen
            case .changesRequested: statusColor = .systemRed
            case .reviewRequired: statusColor = .systemYellow
            case nil: statusColor = .secondaryLabelColor
            }
        }
        meta.append(NSAttributedString(string: "● ", attributes: secondaryAttributes(color: statusColor)))
        meta.append(NSAttributedString(string: "\(pr.reviewStatusLabel)    ", attributes: secondaryAttributes()))

        if let checks = pr.checks {
            let glyph: String
            let color: NSColor
            if checks.isFailing {
                glyph = "✕"; color = .systemRed
            } else if checks.isPending {
                glyph = "●"; color = .systemYellow
            } else {
                glyph = "✓"; color = .systemGreen
            }
            meta.append(NSAttributedString(string: "\(glyph) ", attributes: secondaryAttributes(color: color)))
            meta.append(NSAttributedString(string: "\(checks.passed)/\(checks.total)    ", attributes: secondaryAttributes()))
        }
        if pr.mergeable == .conflicting {
            meta.append(NSAttributedString(string: "⚠︎ conflicts    ", attributes: secondaryAttributes(color: .systemOrange)))
        }
        meta.append(NSAttributedString(string: "💬 \(pr.commentCount)", attributes: secondaryAttributes()))

        item.attributedTitle = twoLines(truncate(pr.title, to: 96), meta)
        return item
    }

    // MARK: Settings submenus

    private func updatedWindowMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Updated: \(Settings.shared.updatedWindow.title)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for window in UpdatedWindow.allCases {
            let item = NSMenuItem(title: window.title, action: #selector(selectUpdatedWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window.rawValue
            item.state = window == Settings.shared.updatedWindow ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func refreshIntervalMenu() -> NSMenuItem {
        let current = Settings.shared.refreshInterval
        let parent = NSMenuItem(title: "Refresh every: \(intervalLabel(current))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for seconds in Settings.refreshChoices {
            let item = NSMenuItem(title: intervalLabel(seconds), action: #selector(selectRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == current ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = makeItem("Launch at login", #selector(toggleLaunchAtLogin))
        let isBundle = Bundle.main.bundleURL.pathExtension == "app"
        item.isEnabled = isBundle
        item.state = isBundle && SMAppService.mainApp.status == .enabled ? .on : .off
        if !isBundle {
            item.toolTip = "Available when running the packaged pullbar.app (see make app)."
        }
        return item
    }

    // MARK: - Actions

    @objc private func openPullRequest(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openInbox() {
        NSWorkspace.shared.open(URL(string: "https://github.com/pulls/inbox")!)
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func setToken() {
        let reason = lastError?.localizedDescription
        guard let entered = TokenProvider.prompt(reason: reason) else { return }
        do {
            try Keychain.writeToken(entered)
        } catch {
            lastError = error
            render()
            return
        }
        token = entered
        lastError = nil
        refresh()
    }

    @objc private func selectUpdatedWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let window = UpdatedWindow(rawValue: raw) else { return }
        Settings.shared.updatedWindow = window
        refresh()
    }

    @objc private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        Settings.shared.refreshInterval = seconds
        scheduleTimer()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            lastError = error
            render()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func intervalLabel(_ seconds: TimeInterval) -> String {
        seconds < 120 ? "1 minute" : "\(Int(seconds / 60)) minutes"
    }

    private func secondaryAttributes(color: NSColor = .secondaryLabelColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: color]
    }

    private func twoLines(_ first: String, _ second: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: first + "\n",
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        text.append(second)
        return text
    }

    /// "PullBar version 1.2.3" from the bundle's Info.plist; a bare `swift run`
    /// binary has no bundle version.
    static func versionTitle(info: [String: Any]?) -> String {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return "PullBar development build"
        }
        return "PullBar version \(version)"
    }

    /// Where the build came from, as stamped by Packaging/stamp-build-info.sh:
    /// the `git describe` output and the repository URL. Either can be missing.
    static func buildOrigin(info: [String: Any]?) -> (description: String?, repository: URL?) {
        let description = (info?["PullbarBuildDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let repository = (info?["PullbarSourceRepository"] as? String).flatMap(URL.init(string:))
        return (description, repository)
    }

    #if DEBUG // test access; release builds leave it out
    func titleItemForTesting(info: [String: Any]?) -> NSMenuItem { titleItem(info: info) }
    #endif

    /// The first menu row: name and version, and on a second line the build
    /// description and repository. Clicking it opens the repository.
    private func titleItem(info: [String: Any]?) -> NSMenuItem {
        let title = Self.versionTitle(info: info)
        let origin = Self.buildOrigin(info: info)
        let details = [origin.description, origin.repository.map { ($0.host ?? "") + $0.path }]
            .compactMap { $0 }
            .joined(separator: " · ")

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        if !details.isEmpty {
            text.append(NSAttributedString(string: "\n" + details, attributes: secondaryAttributes()))
        }
        item.attributedTitle = text
        if let repository = origin.repository {
            item.action = #selector(openBuildRepository(_:))
            item.target = self
            item.representedObject = repository
            item.toolTip = "Open \(repository.absoluteString)"
        } else {
            item.isEnabled = false
        }
        return item
    }

    @objc private func openBuildRepository(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}

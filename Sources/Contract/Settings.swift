// Settings.swift — every toggle in the app, in one place.
//
// AppSettings is the single source of truth for user preferences. Each property saves itself to
// UserDefaults when changed. Views bind straight to these properties; services read them when
// they need to decide something. To add a toggle: add a property here, load it in `load()`, and
// show it in Sources/App/Settings.

import Foundation
import Combine

enum DisplayMode: String, CaseIterable, Identifiable { case builtin, main, followFocus; var id: String { rawValue } }
enum ThemeID: String, CaseIterable, Identifiable { case midnight, aurora, ember, synthwave, forest, mono; var id: String { rawValue } }
enum PillStyle: String, CaseIterable, Identifiable { case compact, detailed; var id: String { rawValue } }
enum ExpandTrigger: String, CaseIterable, Identifiable { case hover, click; var id: String { rawValue } }
enum SortMode: String, CaseIterable, Identifiable { case attention, recent, project; var id: String { rawValue } }
enum SoundPack: String, CaseIterable, Identifiable { case chime, arcade, soft, system; var id: String { rawValue } }
enum PillMetric: String, CaseIterable, Identifiable { case none, fiveHour, weekly, context; var id: String { rawValue } }
enum MascotStyle: String, CaseIterable, Identifiable { case orb, pixel, ring; var id: String { rawValue } }

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: General
    @Published var launchAtLogin = true { didSet { save("launchAtLogin", launchAtLogin) } }
    @Published var showMenuBarIcon = true { didSet { save("showMenuBarIcon", showMenuBarIcon) } }
    @Published var displayMode = DisplayMode.builtin { didSet { save("displayMode", displayMode.rawValue) } }
    @Published var hideWhenNoSessions = false { didSet { save("hideWhenNoSessions", hideWhenNoSessions) } }
    @Published var hideInFullScreen = false { didSet { save("hideInFullScreen", hideInFullScreen) } }
    @Published var showOnNonNotchDisplays = true { didSet { save("showOnNonNotchDisplays", showOnNonNotchDisplays) } }

    // MARK: Appearance
    @Published var theme = ThemeID.midnight { didSet { save("theme", theme.rawValue) } }
    @Published var pillStyle = PillStyle.detailed { didSet { save("pillStyle", pillStyle.rawValue) } }
    @Published var showGlow = true { didSet { save("showGlow", showGlow) } }
    @Published var showParticles = true { didSet { save("showParticles", showParticles) } }
    @Published var showMascot = true { didSet { save("showMascot", showMascot) } }
    @Published var mascotStyle = MascotStyle.orb { didSet { save("mascotStyle", mascotStyle.rawValue) } }
    @Published var useAgentColors = true { didSet { save("useAgentColors", useAgentColors) } }
    @Published var reduceMotion = false { didSet { save("reduceMotion", reduceMotion) } }
    /// Expanded panel width in points (420...760).
    @Published var panelWidth = 400.0 { didSet { save("panelWidth", panelWidth) } }
    /// Expanded panel maximum height in points (320...720).
    @Published var panelMaxHeight = 520.0 { didSet { save("panelMaxHeight", panelMaxHeight) } }
    /// Multiplier applied to all text sizes (0.85...1.3).
    @Published var textScale = 1.0 { didSet { save("textScale", textScale) } }
    @Published var showToolSparkline = true { didSet { save("showToolSparkline", showToolSparkline) } }
    @Published var showElapsedTime = true { didSet { save("showElapsedTime", showElapsedTime) } }
    @Published var showGitBranch = false { didSet { save("showGitBranch", showGitBranch) } }
    @Published var showModel = false { didSet { save("showModel", showModel) } }
    @Published var showProjectPath = false { didSet { save("showProjectPath", showProjectPath) } }

    // MARK: Behavior
    @Published var expandTrigger = ExpandTrigger.hover { didSet { save("expandTrigger", expandTrigger.rawValue) } }
    /// Seconds the pointer must rest on the pill before it opens (0...0.8).
    @Published var hoverDelay = 0.6 { didSet { save("hoverDelay", hoverDelay) } }
    /// Seconds after the pointer leaves before the panel closes (0...2).
    @Published var collapseDelay = 0.4 { didSet { save("collapseDelay", collapseDelay) } }
    @Published var autoExpandOnAttention = true { didSet { save("autoExpandOnAttention", autoExpandOnAttention) } }
    @Published var autoExpandOnDone = false { didSet { save("autoExpandOnDone", autoExpandOnDone) } }
    @Published var keepExpandedWhilePending = true { didSet { save("keepExpandedWhilePending", keepExpandedWhilePending) } }
    @Published var sortMode = SortMode.attention { didSet { save("sortMode", sortMode.rawValue) } }
    /// Minutes before an idle or finished card is removed. 0 = never.
    @Published var idleCleanupMinutes = 120.0 { didSet { save("idleCleanupMinutes", idleCleanupMinutes) } }
    @Published var showHeadlessSessions = false { didSet { save("showHeadlessSessions", showHeadlessSessions) } }
    @Published var showDesktopAppSessions = true { didSet { save("showDesktopAppSessions", showDesktopAppSessions) } }
    @Published var showSubagents = true { didSet { save("showSubagents", showSubagents) } }

    // MARK: Sounds and notifications
    @Published var soundsEnabled = true { didSet { save("soundsEnabled", soundsEnabled) } }
    /// 0...1.
    @Published var volume = 0.6 { didSet { save("volume", volume) } }
    @Published var soundPack = SoundPack.chime { didSet { save("soundPack", soundPack.rawValue) } }
    @Published var soundOnDone = true { didSet { save("soundOnDone", soundOnDone) } }
    @Published var soundOnApproval = true { didSet { save("soundOnApproval", soundOnApproval) } }
    @Published var soundOnQuestion = true { didSet { save("soundOnQuestion", soundOnQuestion) } }
    @Published var soundOnError = true { didSet { save("soundOnError", soundOnError) } }
    @Published var soundOnStart = false { didSet { save("soundOnStart", soundOnStart) } }
    /// Stay quiet when the session's own terminal tab is already in front.
    @Published var muteWhenTerminalFocused = true { didSet { save("muteWhenTerminalFocused", muteWhenTerminalFocused) } }
    @Published var quietHoursEnabled = false { didSet { save("quietHoursEnabled", quietHoursEnabled) } }
    /// Hour of day 0...23.
    @Published var quietStartHour = 22 { didSet { save("quietStartHour", quietStartHour) } }
    @Published var quietEndHour = 8 { didSet { save("quietEndHour", quietEndHour) } }
    @Published var systemNotifications = false { didSet { save("systemNotifications", systemNotifications) } }
    @Published var reminderEnabled = false { didSet { save("reminderEnabled", reminderEnabled) } }
    /// Seconds a request may wait before a reminder sound (30...600).
    @Published var reminderSeconds = 120.0 { didSet { save("reminderSeconds", reminderSeconds) } }

    // MARK: Approvals
    /// When off, Perch only notifies and the agent's own prompt handles permissions.
    @Published var approvalsInNotch = true { didSet { save("approvalsInNotch", approvalsInNotch) } }
    @Published var questionsInNotch = true { didSet { save("questionsInNotch", questionsInNotch) } }
    @Published var planReviewInNotch = true { didSet { save("planReviewInNotch", planReviewInNotch) } }
    @Published var showDiffPreview = true { didSet { save("showDiffPreview", showDiffPreview) } }
    /// Maximum diff lines shown on an approval card (10...200).
    @Published var diffMaxLines = 40 { didSet { save("diffMaxLines", diffMaxLines) } }
    @Published var showAlwaysAllow = true { didSet { save("showAlwaysAllow", showAlwaysAllow) } }
    /// Keyboard shortcuts for cards. Only active while the panel is open; never global.
    @Published var shortcutsEnabled = true { didSet { save("shortcutsEnabled", shortcutsEnabled) } }
    /// Ask for a second click before allowing commands flagged as dangerous.
    @Published var confirmDangerous = true { didSet { save("confirmDangerous", confirmDangerous) } }
    /// Automatically allow tools that only read (Read, Glob, Grep...). Off by default.
    @Published var autoAllowReadOnly = false { didSet { save("autoAllowReadOnly", autoAllowReadOnly) } }

    // MARK: Agents
    @Published var claudeEnabled = true { didSet { save("claudeEnabled", claudeEnabled) } }
    @Published var codexEnabled = true { didSet { save("codexEnabled", codexEnabled) } }
    @Published var antigravityEnabled = true { didSet { save("antigravityEnabled", antigravityEnabled) } }
    @Published var geminiEnabled = true { didSet { save("geminiEnabled", geminiEnabled) } }

    // MARK: Usage
    @Published var showUsageInPill = true { didSet { save("showUsageInPill", showUsageInPill) } }
    @Published var pillMetric = PillMetric.fiveHour { didSet { save("pillMetric", pillMetric.rawValue) } }
    @Published var showCostEstimates = true { didSet { save("showCostEstimates", showCostEstimates) } }
    /// Show "remaining" instead of "used" for limits.
    @Published var usageShowRemaining = false { didSet { save("usageShowRemaining", usageShowRemaining) } }
    /// Minutes between background rescans of usage files (1...60).
    @Published var usageRefreshMinutes = 5.0 { didSet { save("usageRefreshMinutes", usageRefreshMinutes) } }
    @Published var collectActivityStats = true { didSet { save("collectActivityStats", collectActivityStats) } }
    @Published var usageWarnings = true { didSet { save("usageWarnings", usageWarnings) } }
    /// Ask Anthropic for Claude's limits every few minutes, using Claude Code's saved login. Off by default.
    @Published var liveClaudeLimits = false { didSet { save("liveClaudeLimits", liveClaudeLimits) } }
    /// Warn when a limit passes this percentage (50...95).
    @Published var warnAtPercent = 80.0 { didSet { save("warnAtPercent", warnAtPercent) } }

    // MARK: Advanced
    @Published var activityLogEnabled = true { didSet { save("activityLogEnabled", activityLogEnabled) } }
    @Published var debugLogging = false { didSet { save("debugLogging", debugLogging) } }
    @Published var hasCompletedOnboarding = false { didSet { save("hasCompletedOnboarding", hasCompletedOnboarding) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func isEnabled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        case .antigravity: return antigravityEnabled
        case .gemini: return geminiEnabled
        }
    }

    func setEnabled(_ agent: AgentKind, _ on: Bool) {
        switch agent {
        case .claude: claudeEnabled = on
        case .codex: codexEnabled = on
        case .antigravity: antigravityEnabled = on
        case .gemini: geminiEnabled = on
        }
    }

    /// True right now if quiet hours are on and the current hour falls inside them.
    func inQuietHours(at date: Date = Date()) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: date)
        if quietStartHour == quietEndHour { return false }
        return quietStartHour < quietEndHour
            ? (hour >= quietStartHour && hour < quietEndHour)
            : (hour >= quietStartHour || hour < quietEndHour)
    }

    /// Forgets every saved preference and returns to the built-in defaults.
    func resetToDefaults() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "local.perch.defaults-template-\(UUID().uuidString)") ?? .standard)
        copyValues(from: fresh)
    }

    // MARK: Storage

    private static let prefix = "perch."

    private func save(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        defaults.set(value, forKey: Self.prefix + key)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: Self.prefix + key) as? Bool ?? fallback }
    private func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: Self.prefix + key) as? Double ?? fallback }
    private func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: Self.prefix + key) as? Int ?? fallback }
    private func choice<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
        (defaults.string(forKey: Self.prefix + key)).flatMap(E.init(rawValue:)) ?? fallback
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        launchAtLogin = bool("launchAtLogin", launchAtLogin)
        showMenuBarIcon = bool("showMenuBarIcon", showMenuBarIcon)
        displayMode = choice("displayMode", displayMode)
        hideWhenNoSessions = bool("hideWhenNoSessions", hideWhenNoSessions)
        hideInFullScreen = bool("hideInFullScreen", hideInFullScreen)
        showOnNonNotchDisplays = bool("showOnNonNotchDisplays", showOnNonNotchDisplays)
        theme = choice("theme", theme)
        pillStyle = choice("pillStyle", pillStyle)
        showGlow = bool("showGlow", showGlow)
        showParticles = bool("showParticles", showParticles)
        showMascot = bool("showMascot", showMascot)
        mascotStyle = choice("mascotStyle", mascotStyle)
        useAgentColors = bool("useAgentColors", useAgentColors)
        reduceMotion = bool("reduceMotion", reduceMotion)
        panelWidth = double("panelWidth", panelWidth)
        panelMaxHeight = double("panelMaxHeight", panelMaxHeight)
        textScale = double("textScale", textScale)
        showToolSparkline = bool("showToolSparkline", showToolSparkline)
        showElapsedTime = bool("showElapsedTime", showElapsedTime)
        showGitBranch = bool("showGitBranch", showGitBranch)
        showModel = bool("showModel", showModel)
        showProjectPath = bool("showProjectPath", showProjectPath)
        expandTrigger = choice("expandTrigger", expandTrigger)
        hoverDelay = double("hoverDelay", hoverDelay)
        collapseDelay = double("collapseDelay", collapseDelay)
        autoExpandOnAttention = bool("autoExpandOnAttention", autoExpandOnAttention)
        autoExpandOnDone = bool("autoExpandOnDone", autoExpandOnDone)
        keepExpandedWhilePending = bool("keepExpandedWhilePending", keepExpandedWhilePending)
        sortMode = choice("sortMode", sortMode)
        idleCleanupMinutes = double("idleCleanupMinutes", idleCleanupMinutes)
        showHeadlessSessions = bool("showHeadlessSessions", showHeadlessSessions)
        showDesktopAppSessions = bool("showDesktopAppSessions", showDesktopAppSessions)
        showSubagents = bool("showSubagents", showSubagents)
        soundsEnabled = bool("soundsEnabled", soundsEnabled)
        volume = double("volume", volume)
        soundPack = choice("soundPack", soundPack)
        soundOnDone = bool("soundOnDone", soundOnDone)
        soundOnApproval = bool("soundOnApproval", soundOnApproval)
        soundOnQuestion = bool("soundOnQuestion", soundOnQuestion)
        soundOnError = bool("soundOnError", soundOnError)
        soundOnStart = bool("soundOnStart", soundOnStart)
        muteWhenTerminalFocused = bool("muteWhenTerminalFocused", muteWhenTerminalFocused)
        quietHoursEnabled = bool("quietHoursEnabled", quietHoursEnabled)
        quietStartHour = int("quietStartHour", quietStartHour)
        quietEndHour = int("quietEndHour", quietEndHour)
        systemNotifications = bool("systemNotifications", systemNotifications)
        reminderEnabled = bool("reminderEnabled", reminderEnabled)
        reminderSeconds = double("reminderSeconds", reminderSeconds)
        approvalsInNotch = bool("approvalsInNotch", approvalsInNotch)
        questionsInNotch = bool("questionsInNotch", questionsInNotch)
        planReviewInNotch = bool("planReviewInNotch", planReviewInNotch)
        showDiffPreview = bool("showDiffPreview", showDiffPreview)
        diffMaxLines = int("diffMaxLines", diffMaxLines)
        showAlwaysAllow = bool("showAlwaysAllow", showAlwaysAllow)
        shortcutsEnabled = bool("shortcutsEnabled", shortcutsEnabled)
        confirmDangerous = bool("confirmDangerous", confirmDangerous)
        autoAllowReadOnly = bool("autoAllowReadOnly", autoAllowReadOnly)
        claudeEnabled = bool("claudeEnabled", claudeEnabled)
        codexEnabled = bool("codexEnabled", codexEnabled)
        antigravityEnabled = bool("antigravityEnabled", antigravityEnabled)
        geminiEnabled = bool("geminiEnabled", geminiEnabled)
        showUsageInPill = bool("showUsageInPill", showUsageInPill)
        pillMetric = choice("pillMetric", pillMetric)
        showCostEstimates = bool("showCostEstimates", showCostEstimates)
        usageShowRemaining = bool("usageShowRemaining", usageShowRemaining)
        usageRefreshMinutes = double("usageRefreshMinutes", usageRefreshMinutes)
        collectActivityStats = bool("collectActivityStats", collectActivityStats)
        usageWarnings = bool("usageWarnings", usageWarnings)
        liveClaudeLimits = bool("liveClaudeLimits", liveClaudeLimits)
        warnAtPercent = double("warnAtPercent", warnAtPercent)
        activityLogEnabled = bool("activityLogEnabled", activityLogEnabled)
        debugLogging = bool("debugLogging", debugLogging)
        hasCompletedOnboarding = bool("hasCompletedOnboarding", hasCompletedOnboarding)
    }

    private func copyValues(from o: AppSettings) {
        launchAtLogin = o.launchAtLogin; showMenuBarIcon = o.showMenuBarIcon; displayMode = o.displayMode
        hideWhenNoSessions = o.hideWhenNoSessions; hideInFullScreen = o.hideInFullScreen
        showOnNonNotchDisplays = o.showOnNonNotchDisplays
        theme = o.theme; pillStyle = o.pillStyle; showGlow = o.showGlow; showParticles = o.showParticles
        showMascot = o.showMascot; mascotStyle = o.mascotStyle; useAgentColors = o.useAgentColors
        reduceMotion = o.reduceMotion; panelWidth = o.panelWidth; panelMaxHeight = o.panelMaxHeight
        textScale = o.textScale; showToolSparkline = o.showToolSparkline; showElapsedTime = o.showElapsedTime
        showGitBranch = o.showGitBranch; showModel = o.showModel; showProjectPath = o.showProjectPath
        expandTrigger = o.expandTrigger; hoverDelay = o.hoverDelay; collapseDelay = o.collapseDelay
        autoExpandOnAttention = o.autoExpandOnAttention; autoExpandOnDone = o.autoExpandOnDone
        keepExpandedWhilePending = o.keepExpandedWhilePending; sortMode = o.sortMode
        idleCleanupMinutes = o.idleCleanupMinutes; showHeadlessSessions = o.showHeadlessSessions
        showDesktopAppSessions = o.showDesktopAppSessions; showSubagents = o.showSubagents
        soundsEnabled = o.soundsEnabled; volume = o.volume; soundPack = o.soundPack; soundOnDone = o.soundOnDone
        soundOnApproval = o.soundOnApproval; soundOnQuestion = o.soundOnQuestion; soundOnError = o.soundOnError
        soundOnStart = o.soundOnStart; muteWhenTerminalFocused = o.muteWhenTerminalFocused
        quietHoursEnabled = o.quietHoursEnabled; quietStartHour = o.quietStartHour; quietEndHour = o.quietEndHour
        systemNotifications = o.systemNotifications; reminderEnabled = o.reminderEnabled
        reminderSeconds = o.reminderSeconds
        approvalsInNotch = o.approvalsInNotch; questionsInNotch = o.questionsInNotch
        planReviewInNotch = o.planReviewInNotch; showDiffPreview = o.showDiffPreview; diffMaxLines = o.diffMaxLines
        showAlwaysAllow = o.showAlwaysAllow; shortcutsEnabled = o.shortcutsEnabled
        confirmDangerous = o.confirmDangerous; autoAllowReadOnly = o.autoAllowReadOnly
        claudeEnabled = o.claudeEnabled; codexEnabled = o.codexEnabled; antigravityEnabled = o.antigravityEnabled
        geminiEnabled = o.geminiEnabled
        showUsageInPill = o.showUsageInPill; pillMetric = o.pillMetric; showCostEstimates = o.showCostEstimates
        usageShowRemaining = o.usageShowRemaining; usageRefreshMinutes = o.usageRefreshMinutes
        collectActivityStats = o.collectActivityStats; usageWarnings = o.usageWarnings; liveClaudeLimits = o.liveClaudeLimits; warnAtPercent = o.warnAtPercent
        activityLogEnabled = o.activityLogEnabled; debugLogging = o.debugLogging
        hasCompletedOnboarding = o.hasCompletedOnboarding
    }
}

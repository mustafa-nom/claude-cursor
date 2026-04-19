//
//  ClaudeCursorApp.swift
//  claude-cursor
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct ClaudeCursorApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager: CompanionManager = {
        // Reset all panel-section toggles to OFF on every app launch.
        // Keys MUST be cleared before CompanionManager() runs, because its
        // `@Published` stored properties read these UserDefaults values in
        // their default-value expressions (stored-property initializers run
        // before the body of init()).
        //
        // One-time state flags (`hasCompletedOnboarding`,
        // `hasScreenContentPermission`, `selectedClaudeModel`) are
        // intentionally *not* reset — those represent durable onboarding /
        // permission state, not panel toggles.
        let panelToggleUserDefaultsKeys: [String] = [
            "isTutorModeEnabled",
            "isWikiKnowledgeEnabled",
            "isAutoCopyResponseEnabled",
            "isShowChatEnabled",
            "ClaudeCursor.isAutomationExperimentalEnabled"
        ]
        for panelToggleKey in panelToggleUserDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: panelToggleKey)
        }
        return CompanionManager()
    }()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 ClaudeCursor: Starting...")
        print("🎯 ClaudeCursor: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClaudeCursorAnalytics.configure()
        ClaudeCursorAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 ClaudeCursor: Registered as login item")
            } catch {
                print("⚠️ ClaudeCursor: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ ClaudeCursor: Sparkle updater failed to start: \(error)")
        }
    }
}

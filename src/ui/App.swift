import Cocoa
import Darwin
import LetsMove
import ShortcutRecorder
import Preferences

let cgsMainConnectionId = CGSMainConnectionID()

class App: NSApplication, NSApplicationDelegate {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    static let licence = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as! String
    static let repository = "https://github.com/lwouis/alt-tab-macos"
    static var app: App!
    static let shortcutMonitor = LocalShortcutMonitor()
    var statusItem: NSStatusItem!
    var thumbnailsPanel: ThumbnailsPanel!
    var preferencesWindowController: PreferencesWindowController!
    var feedbackWindow: FeedbackWindow?
    var isFirstSummon = true
    var appIsBeingUsed = false

    override init() {
        super.init()
        delegate = self
        App.app = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if !DEBUG
        PFMoveToApplicationsFolderIfNecessary()
        #endif
        Preferences.migratePreferences()
        Preferences.registerDefaults()
        self.statusItem = Menubar.make()
        self.loadMainMenuXib()
        self.thumbnailsPanel = ThumbnailsPanel()
        Spaces.initialDiscovery()
        Applications.initialDiscovery()
        self.loadPreferencesWindow()
        // TODO: undeterministic; events in the queue may still be processing; good enough for now
        DispatchQueue.main.async { () -> () in Windows.sortByLevel() }
        self.preloadWindows()
        SystemPermissions.ensureAccessibilityCheckboxIsChecked
        //        SystemPermissions.ensureScreenRecordingCheckboxIsChecked()
    }

    // pre-load some windows so they are faster on first display
    private func preloadWindows() {
        preferencesWindowController.show()
        preferencesWindowController.window!.orderOut(nil)
        thumbnailsPanel.orderFront(nil)
        thumbnailsPanel.orderOut(nil)
    }

    private func loadPreferencesWindow() {
        let tabs = [
            GeneralTab(),
            AppearanceTab(),
            UpdatesTab(),
            AboutTab(),
            AcknowledgmentsTab(),
        ]
        // pre-load tabs so we can interact with them before the user opens the preferences window
        tabs.forEach { (tab: NSViewController) in tab.loadView() }
        preferencesWindowController = PreferencesWindowController(preferencePanes: tabs as! [PreferencePane])
    }

    // keyboard shortcuts are broken without a menu. We generated the default menu from XCode and load it
    // see https://stackoverflow.com/a/3746058/2249756
    private func loadMainMenuXib() {
        var menuObjects: NSArray?
        Bundle.main.loadNibNamed("MainMenu", owner: self, topLevelObjects: &menuObjects)
        menu = menuObjects?.first(where: { $0 is NSMenu }) as? NSMenu
    }

    // we put application code here which should be executed on init() and Preferences change
    func resetPreferencesDependentComponents() {
        ThumbnailsView.recycledViews = ThumbnailsView.recycledViews.map { _ in ThumbnailView() }
        thumbnailsPanel.thumbnailsView.layer!.cornerRadius = Preferences.windowCornerRadius
    }

    func hideUi() {
        debugPrint("hideUi")
        appIsBeingUsed = false
        isFirstSummon = true
        thumbnailsPanel.orderOut(nil)
    }

    func closeSelectedWindow() {
        Windows.focusedWindow()?.close()
    }

    func minDeminSelectedWindow() {
        Windows.focusedWindow()?.minDemin()
    }

    func quitSelectedApp() {
        Windows.focusedWindow()?.quitApp()
    }

    func hideShowSelectedApp() {
        Windows.focusedWindow()?.hideShowApp()
    }

    func focusTarget() {
        debugPrint("focusTarget")
        focusSelectedWindow(Windows.focusedWindow())
    }

    @objc func checkForUpdatesNow(_ sender: NSMenuItem) {
        UpdatesTab.checkForUpdatesNow(sender)
    }

    @objc func showPreferencesPanel() {
        Screen.repositionPanel(preferencesWindowController.window!, Screen.preferred(), .appleCentered)
        preferencesWindowController.show()
    }

    @objc func showFeedbackPanel() {
        if feedbackWindow == nil {
            feedbackWindow = FeedbackWindow()
        }
        Screen.repositionPanel(feedbackWindow!, Screen.preferred(), .appleCentered)
        feedbackWindow?.show()
    }

    @objc
    func showUi() {
        appIsBeingUsed = true
        appIsBeingUsed = true
        DispatchQueue.main.async { () -> () in self.showUiOrCycleSelection(0) }
    }

    func cycleSelection(_ step: Int) {
        Windows.cycleFocusedWindowIndex(step)
    }

    func focusSelectedWindow(_ window: Window?) {
        hideUi()
        guard !CGWindow.isMissionControlActive() else { return }
        window?.focus()
    }

    func reopenUi() {
        thumbnailsPanel.orderOut(nil)
        rebuildUi()
    }

    func refreshOpenUi(_ windowsToUpdate: [Window]? = nil, _ updateWindowsInfo: Bool = false) {
        guard appIsBeingUsed else { return }
        let currentScreen = Screen.preferred() // fix screen between steps since it could change (e.g. mouse moved to another screen)
        // workaround: when Preferences > Mission Control > "Displays have separate Spaces" is unchecked,
        // switching between displays doesn't trigger .activeSpaceDidChangeNotification; we get the latest manually
        Spaces.refreshCurrentSpaceId()
        refreshSpecificWindows(windowsToUpdate, updateWindowsInfo, currentScreen)
        guard appIsBeingUsed else { return }
        thumbnailsPanel.thumbnailsView.updateItems(currentScreen)
        guard appIsBeingUsed else { return }
        thumbnailsPanel.setFrame(thumbnailsPanel.thumbnailsView.frame, display: false)
        guard appIsBeingUsed else { return }
        Screen.repositionPanel(thumbnailsPanel, currentScreen, .appleCentered)
    }

    private func refreshSpecificWindows(_ windowsToUpdate: [Window]?, _ updateWindowsInfo: Bool, _ currentScreen: NSScreen) -> ()? {
        windowsToUpdate?.forEach { (window: Window) in
            guard appIsBeingUsed else { return }
            window.refreshThumbnail()
            if updateWindowsInfo {
                Windows.refreshIfWindowShouldBeShownToTheUser(window, currentScreen)
                if !window.shouldShowTheUser && window.cgWindowId == Windows.focusedWindow()!.cgWindowId {
                    let stepWithClosestWindow = Windows.windowIndexAfterCycling(-1) > Windows.focusedWindowIndex ? 1 : -1
                    Windows.cycleFocusedWindowIndex(stepWithClosestWindow)
                } else {
                    Windows.updatesWindowSpace(window)
                }
            }
        }
    }

    func showUiOrCycleSelection(_ step: Int) {
        debugPrint("showUiOrCycleSelection", step)
        if isFirstSummon {
            debugPrint("showUiOrCycleSelection: isFirstSummon")
            isFirstSummon = false
            if Windows.list.count == 0 || CGWindow.isMissionControlActive() { hideUi(); return }
            // TODO: find a way to update isSingleSpace by listening to space creation, instead of on every trigger
            Spaces.idsAndIndexes = Spaces.allIdsAndIndexes()
            // TODO: find a way to update space index when windows are moved to another space, instead of on every trigger
            Windows.updateSpaces()
            let screen = Screen.preferred()
            Windows.refreshWhichWindowsToShowTheUser(screen)
            if Windows.list.first(where: { $0.shouldShowTheUser }) == nil { hideUi(); return }
            Windows.updateFocusedWindowIndex(0)
            Windows.cycleFocusedWindowIndex(step)
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Preferences.windowDisplayDelay) { () -> () in
                self.rebuildUi()
            }
        } else {
            cycleSelection(step)
        }
    }

    func rebuildUi() {
        guard appIsBeingUsed else { return }
        Windows.refreshAllThumbnails()
        guard appIsBeingUsed else { return }
        refreshOpenUi()
        guard appIsBeingUsed else { return }
        thumbnailsPanel.show()
    }
}

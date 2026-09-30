//
//  GlassyBatterySettingsWindow.swift
//  GlassyBattery
//
//  Replaces the SwiftUI `Settings { }` scene, which uses a non-standard window template
//  (extra inset chrome / title bar lines vs. System Settings). This file is the supported
//  entry point; do not reintroduce `Settings { }` for this app.
//

import AppKit
import SwiftUI

let glassyBatterySettingsWindowId = "GlassyBatterySettings"

/// Root view for the settings `Window` scene: full-size content + window hooks + `openWindow` capture.
struct GlassyBatterySettingsWindowRoot: View {
    var body: some View {
        SettingsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                WindowAccessor(onWindowOpen: Self.configureWindow)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                GlassyBatterySettingsOpenWindowBinder()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
    }

    private static func configureWindow(_ window: NSWindow?) {
        guard let w = window else { return }
        w.titlebarSeparatorStyle = .none
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
    }
}

private struct GlassyBatterySettingsOpenWindowBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                GlassyBatterySettingsWindowOpener.shared.register(openWindow)
            }
    }
}

final class GlassyBatterySettingsWindowOpener {
    static let shared = GlassyBatterySettingsWindowOpener()
    private var openWindow: OpenWindowAction?

    func register(_ action: OpenWindowAction) {
        openWindow = action
    }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let openWindow {
            openWindow(id: glassyBatterySettingsWindowId)
            return
        }
        for w in NSApp.windows where isGlassyBatterySettingsWindow(w) {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}

/// Called from the Dock menu, status item, and other non-SwiftUI entry points.
func openGlassyBatterySettingsWindow() {
    GlassyBatterySettingsWindowOpener.shared.open()
}

/// The title follows the selected pane ("General", ...), so match the scene id SwiftUI uses for the
/// window's identifier and frame autosave name instead.
private func isGlassyBatterySettingsWindow(_ w: NSWindow) -> Bool {
    w.frameAutosaveName == glassyBatterySettingsWindowId
        || w.identifier?.rawValue.hasPrefix(glassyBatterySettingsWindowId) == true
}

/// Hides the settings `Window` without quitting the app (e.g. before showing the Dock battery panel).
func orderOutGlassyBatterySettingsWindow() {
    for w in NSApp.windows where isGlassyBatterySettingsWindow(w) {
        w.orderOut(nil)
    }
}

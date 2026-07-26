//
//  CodexMicroRemoteApp.swift
//  AgentMicro — iPhone control surface for coding agents.
//
//  Protocol reference: ../../docs/codex-micro-protocol.md
//

import SwiftUI
import UIKit

@main
struct CodexMicroRemoteApp: App {
    @StateObject private var peripheral = CodexMicroPeripheral()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The control surface lives inside a `.page`-style TabView (swipe
        // between the Codex and VS Code boards). That TabView is backed by a
        // UIScrollView whose default `delaysContentTouches` withholds the
        // initial touch-down from the keys beneath it while it decides whether
        // the gesture is a horizontal page swipe. The result is that key
        // presses feel dead — they neither light up nor fire — unless the
        // finger happens to land perfectly still. Disabling the delay app-wide
        // lets a press register and glow the instant a finger lands; a
        // deliberate horizontal drag still pages between boards.
        UIScrollView.appearance().delaysContentTouches = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(peripheral)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Hold the screen awake while the app is foreground. Auto-lock
                    // suspends the app, which tears down the CBPeripheralManager link
                    // to the Mac helper ("disconnected from us") and pushes the
                    // 128-bit bridge service UUID into BLE overflow advertising that
                    // the Mac's service-filtered scan rediscovers only unreliably —
                    // the reconnect churn that destabilizes the bridge. Keeping the
                    // display on keeps the link up. Restored when we leave the
                    // foreground so we never block auto-lock in the background.
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                    if phase == .active {
                        peripheral.applicationDidBecomeActive()
                    } else {
                        peripheral.applicationWillResignActive()
                    }
                }
        }
    }
}

// main.swift
//
// GarminDisconnect entry point. Spins up the AppKit run loop with our AppDelegate.
// Everything else flows from AppDelegate.applicationDidFinishLaunching.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

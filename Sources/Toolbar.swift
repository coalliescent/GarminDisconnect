// Toolbar.swift
//
// NSToolbar setup for the main window. Three toolbar items:
//
//   1. Tab segmented control (Overview / Activities / Wellness / Sleep / Sync)
//      — lives at the leading edge so it acts as a tab bar.
//   2. Device picker (NSPopUpButton wrapped in NSToolbarItem)
//      — hidden when there's only one device or zero devices.
//   3. Sync button (NSButton)
//      — Phase 3 stub. Phase 6 wires it up to GarminDumpRunner.
//
// MainWindowController is the NSToolbarDelegate, but the actual NSToolbarItem
// construction lives here so the controller doesn't drown in factory code.

import AppKit

/// Stable identifiers for every NSToolbarItem we create. NSToolbar uses these to
/// remember which items the user has shown/hidden across launches.
enum ToolbarID {
    static let toolbar = NSToolbar.Identifier("GarminDisconnect.MainToolbar")

    static let tabs = NSToolbarItem.Identifier("GarminDisconnect.tabs")
    static let devicePicker = NSToolbarItem.Identifier("GarminDisconnect.devicePicker")
    static let syncButton = NSToolbarItem.Identifier("GarminDisconnect.syncButton")
}

/// The five top-level tabs the user can switch between. Order matches the segmented
/// control order, which matches the NSView swap order in MainWindowController.
enum Tab: Int, CaseIterable {
    case overview = 0
    case activities = 1
    case wellness = 2
    case sleep = 3
    case sync = 4

    var label: String {
        switch self {
        case .overview:   return "Overview"
        case .activities: return "Activities"
        case .wellness:   return "Wellness"
        case .sleep:      return "Sleep"
        case .sync:       return "Sync"
        }
    }
}

/// Factory + delegate for the main toolbar. Owned by MainWindowController; the
/// `target` is the controller, which routes the action selectors to its own
/// `tabChanged(_:)`, `deviceChanged(_:)`, and `syncRequested(_:)` methods.
final class ToolbarBuilder: NSObject, NSToolbarDelegate {

    private weak var target: MainWindowController?
    private(set) var devicePicker: NSPopUpButton?
    private(set) var devicePickerItem: NSToolbarItem?
    private(set) var tabSegmented: NSSegmentedControl?

    init(target: MainWindowController) {
        self.target = target
        super.init()
    }

    func make() -> NSToolbar {
        let toolbar = NSToolbar(identifier: ToolbarID.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    /// Refresh the device picker after AppState.devices changes. Hides the entire
    /// item when there's ≤1 device, since multi-device is the uncommon case.
    func refreshDevicePicker() {
        guard let picker = devicePicker, let item = devicePickerItem else { return }
        let devices = AppState.shared.devices
        picker.removeAllItems()

        if devices.count <= 1 {
            // Hide the toolbar item entirely. We do this by replacing the popup's
            // sole item with the device name (or nothing) and disabling user
            // interaction; NSToolbar doesn't support runtime hide/show cleanly
            // for arbitrary items, so this is the cleanest workaround.
            if let only = devices.first {
                picker.addItem(withTitle: only.displayName)
            } else {
                picker.addItem(withTitle: "No device")
            }
            picker.isEnabled = false
            item.isEnabled = false
            item.label = ""
            return
        }

        item.isEnabled = true
        item.label = "Device"
        picker.isEnabled = true
        for d in devices {
            picker.addItem(withTitle: d.displayName)
            // Stash the device_id on the menu item for the action callback to read.
            picker.lastItem?.tag = d.id
            picker.lastItem?.representedObject = d.id
        }
        if let selID = AppState.shared.selectedDeviceID,
           let idx = devices.firstIndex(where: { $0.id == selID }) {
            picker.selectItem(at: idx)
        }
    }

    /// Move the segmented control's selection to match the given tab without
    /// firing its action. Used when the controller programmatically switches tabs.
    func setTab(_ tab: Tab) {
        tabSegmented?.selectedSegment = tab.rawValue
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            ToolbarID.tabs,
            .flexibleSpace,
            ToolbarID.devicePicker,
            ToolbarID.syncButton,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
            + [.flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.tabs:
            return makeTabsItem()
        case ToolbarID.devicePicker:
            return makeDevicePickerItem()
        case ToolbarID.syncButton:
            return makeSyncButtonItem()
        default:
            return nil
        }
    }

    // MARK: - Item factories

    private func makeTabsItem() -> NSToolbarItem {
        let segmented = NSSegmentedControl(
            labels: Tab.allCases.map { $0.label },
            trackingMode: .selectOne,
            target: target,
            action: #selector(MainWindowController.tabChanged(_:))
        )
        segmented.segmentStyle = .texturedRounded
        segmented.selectedSegment = Tab.overview.rawValue
        segmented.controlSize = .regular
        // Make sure the labels are wide enough that nothing truncates.
        for (i, t) in Tab.allCases.enumerated() {
            segmented.setWidth(86, forSegment: i)
            segmented.setLabel(t.label, forSegment: i)
        }
        self.tabSegmented = segmented

        let item = NSToolbarItem(itemIdentifier: ToolbarID.tabs)
        item.label = ""  // segmented control labels itself
        item.paletteLabel = "Tabs"
        item.view = segmented
        return item
    }

    private func makeDevicePickerItem() -> NSToolbarItem {
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = target
        popup.action = #selector(MainWindowController.deviceChanged(_:))
        popup.addItem(withTitle: "No device")
        popup.isEnabled = false
        // Constrain explicitly so the toolbar lays it out without minSize/maxSize.
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        popup.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        self.devicePicker = popup

        let item = NSToolbarItem(itemIdentifier: ToolbarID.devicePicker)
        item.label = ""
        item.paletteLabel = "Device"
        item.view = popup
        self.devicePickerItem = item
        return item
    }

    private func makeSyncButtonItem() -> NSToolbarItem {
        let button = NSButton(
            title: "Sync",
            target: target,
            action: #selector(MainWindowController.syncRequested(_:))
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Sync from watch"
        )
        button.imagePosition = .imageLeading
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let item = NSToolbarItem(itemIdentifier: ToolbarID.syncButton)
        item.label = "Sync"
        item.paletteLabel = "Sync"
        item.view = button
        return item
    }
}

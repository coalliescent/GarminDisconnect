// AppState.swift
//
// Process-wide singleton holding the things every view needs to read:
//   - the read-only Database handle
//   - the list of known devices
//   - the currently-selected device
//   - a monotonically-increasing dataVersion that views observe to know when to refresh
//
// AppState is intentionally simple. It is the only class with mutable singleton
// state and it posts NotificationCenter notifications when things change. Views
// observe those notifications and re-query their data; the alternative (KVO,
// Combine, observable objects) would all require either Objective-C tooling or a
// SwiftUI runtime that we deliberately don't depend on.

import AppKit
import Foundation

extension Notification.Name {
    /// Posted when the user picks a different device in the toolbar, OR when the
    /// device list itself changes (e.g. after a sync introduces a new device).
    static let selectedDeviceChanged = Notification.Name(
        "GarminDisconnect.selectedDeviceChanged"
    )

    /// Posted when AppState.dataVersion is bumped — i.e. data on disk has changed
    /// and every visible chart should re-query.
    static let dataVersionChanged = Notification.Name(
        "GarminDisconnect.dataVersionChanged"
    )

    /// Posted when AppState.databaseError changes (e.g. archive disappears or schema
    /// mismatches). Views show a banner / welcome state in response.
    static let databaseStateChanged = Notification.Name(
        "GarminDisconnect.databaseStateChanged"
    )
}

/// What we know about a connected (or previously-connected) Garmin device.
/// Materialized from `SELECT … FROM devices`.
public struct DeviceInfo: Equatable {
    public let id: Int
    public let serial: String
    public let model: String
    public let softwareVersion: String?
    public let lastSeenISO: String

    /// "Instinct 3 - 45mm • 7685" — what the toolbar picker shows.
    public var displayName: String {
        let last4 = serial.suffix(4)
        return "\(model) • \(last4)"
    }
}

/// Where the singleton looks for the database. Resolution order:
///   1. `GARMIN_DISCONNECT_DB` environment variable
///   2. `~/garmin-archive/garmin.db` (the garmin-dump default)
///
/// `open` strips the launching shell's environment, so the env var is normally
/// only seen when the user runs `make run` (which uses `open --env`) or invokes
/// the binary directly. Either way, we accept absolute paths, ~-paths, and
/// relative paths — relative paths get expanded against the current working
/// directory (which for an `open`ed app is `/`, but at least the failure mode is
/// "we tried /Tests/fixtures/tiny.db" instead of a silent fallback).
///
/// We do NOT yet support a Settings UI for picking a different archive — that's
/// out of scope for v1.
private func resolveDatabasePath() -> URL {
    let raw = ProcessInfo.processInfo.environment["GARMIN_DISCONNECT_DB"] ?? ""
    if !raw.isEmpty {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        // Relative path — anchor to the current working directory.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent(expanded)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("garmin-archive/garmin.db")
}

public final class AppState {

    public static let shared = AppState()

    /// Where we last looked for the database. Exposed so the welcome view can
    /// tell the user "we looked here".
    public let databasePath: URL

    /// The opened SQLite handle, or nil if open failed (file missing, schema
    /// mismatch, etc). Views must handle nil — that's the empty/welcome state.
    public private(set) var database: Database?

    /// The most recent error from trying to open the database. Used by the
    /// welcome view to render a useful message.
    public private(set) var databaseError: Error?

    /// Devices visible to the app, in last-seen-desc order.
    public private(set) var devices: [DeviceInfo] = []

    /// The device the user currently has selected. nil = no device chosen yet
    /// (e.g. zero devices in the archive, or first launch with multiple).
    public private(set) var selectedDeviceID: Int?

    /// Bumps every time data on disk changes. Views observe this via the
    /// `dataVersionChanged` notification and re-query.
    public private(set) var dataVersion: Int = 0

    /// `UserDefaults` key for persisting the selected device across launches.
    private let selectedDeviceKey = "GarminDisconnect.selectedDeviceID"

    private init() {
        databasePath = resolveDatabasePath()
        openDatabase()
        loadDevices()
        restoreSelectedDevice()
    }

    // MARK: - Database lifecycle

    /// (Re)open the database. Called from `init()` and after a sync where the file
    /// might have been created for the first time.
    public func openDatabase() {
        do {
            database = try Database(path: databasePath)
            databaseError = nil
        } catch {
            database = nil
            databaseError = error
        }
        NotificationCenter.default.post(name: .databaseStateChanged, object: self)
    }

    /// Refresh the device list from the database. Call after a sync, or when
    /// re-opening the database.
    public func loadDevices() {
        guard let db = database else {
            devices = []
            return
        }
        do {
            let rows = try db.query("""
                SELECT device_id, serial, model, software_version, last_seen_utc
                FROM devices
                ORDER BY last_seen_utc DESC
                """)
            devices = rows.compactMap { row in
                guard let id = row.int("device_id"),
                      let serial = row.string("serial") else { return nil }
                return DeviceInfo(
                    id: id,
                    serial: serial,
                    model: row.string("model") ?? "Unknown",
                    softwareVersion: row.string("software_version"),
                    lastSeenISO: row.string("last_seen_utc") ?? ""
                )
            }
        } catch {
            // Treat a query failure the same as an empty device list. The error
            // will surface to the welcome view via databaseError on next openDatabase().
            devices = []
        }
    }

    // MARK: - Device selection

    /// Restore the selected device from UserDefaults, falling back to the most
    /// recently seen device, then nil if there are zero devices.
    private func restoreSelectedDevice() {
        let savedID = UserDefaults.standard.object(forKey: selectedDeviceKey) as? Int
        if let savedID = savedID, devices.contains(where: { $0.id == savedID }) {
            selectedDeviceID = savedID
        } else {
            selectedDeviceID = devices.first?.id  // most recent (last_seen DESC)
        }
    }

    /// Change the selected device. Persists to UserDefaults and posts a notification
    /// so views re-query with the new device_id filter.
    public func selectDevice(_ id: Int) {
        guard devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = id
        UserDefaults.standard.set(id, forKey: selectedDeviceKey)
        NotificationCenter.default.post(name: .selectedDeviceChanged, object: self)
    }

    /// The currently-selected device, or nil if none.
    public var selectedDevice: DeviceInfo? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first(where: { $0.id == id })
    }

    // MARK: - Data version

    /// Bump the data version. Call after a successful sync. Triggers all
    /// observing views to re-query.
    public func bumpDataVersion() {
        dataVersion += 1
        NotificationCenter.default.post(name: .dataVersionChanged, object: self)
    }
}

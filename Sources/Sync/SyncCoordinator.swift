// SyncCoordinator.swift
//
// State machine that owns the sync UX. There's exactly one in the app, owned
// by AppState. Views (toolbar sync button, sync tab) read its current state
// to decide what to show; they kick state transitions by calling
// `requestSync()`.
//
// State transitions:
//   idle → syncing (via requestSync)
//   syncing → idle (on completion or failure, with the result captured)
//
// We deliberately don't have a "checking" or "confirming" intermediate state
// for v1 — clicking Sync just runs `garmin-dump pull` immediately. Adding a
// pre-pull `garmin-dump status` confirmation step is a Phase 7+ refinement.
//
// Sync runs on a background thread (DispatchQueue.global) so the AppKit run
// loop stays responsive during the long-running pull. State updates are
// posted back to the main queue before broadcasting.

import AppKit
import Foundation

extension Notification.Name {
    static let syncStateChanged = Notification.Name("GarminDisconnect.syncStateChanged")
}

public final class SyncCoordinator {

    public enum State {
        case idle
        case syncing
        case done(PullResult)
        case failed(Error)
    }

    public static let shared = SyncCoordinator()

    public private(set) var state: State = .idle

    private let queue = DispatchQueue(label: "dev.opal.garmin-disconnect.sync")
    private init() {}

    public var isBusy: Bool {
        if case .syncing = state { return true }
        return false
    }

    /// Kick off a sync. Returns immediately; observe `syncStateChanged` to
    /// react to completion. No-op if a sync is already running.
    public func requestSync() {
        if case .syncing = state { return }
        transition(to: .syncing)

        queue.async {
            let result: Result<PullResult, Error>
            do {
                let r = try GarminDumpRunner.runPull()
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    self.transition(to: .done(r))
                case .failure(let e):
                    self.transition(to: .failed(e))
                }
                // After a sync, the database may have new rows. Re-open it
                // (no-op if already open) and re-load devices, then bump the
                // dataVersion so all visible charts re-query.
                AppState.shared.openDatabase()
                AppState.shared.loadDevices()
                AppState.shared.bumpDataVersion()

                // Auto-revert to idle after a short pause so the UI doesn't
                // get stuck on a stale "done" state. The captured result lives
                // on in the runs table for the user to inspect.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.transition(to: .idle)
                }
            }
        }
    }

    /// Convenience: present an alert with the most-recent failure. Used by
    /// the toolbar / sync tab when the user wants to see what went wrong.
    public func describeError() -> String? {
        if case .failed(let e) = state { return "\(e)" }
        return nil
    }

    private func transition(to newState: State) {
        state = newState
        NotificationCenter.default.post(name: .syncStateChanged, object: self)
    }
}

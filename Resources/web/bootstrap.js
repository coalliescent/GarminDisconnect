// bootstrap.js — Swift→JS dispatch + tab switching + UI plumbing.
//
// Three responsibilities:
//   1. window.GarminDisconnect.render(payload) — chart-id dispatch into the
//      renderers defined in charts.js (Plotly traces) AND the "non-Plotly"
//      renderers below (insight cards, activity list, sync panel runs table).
//   2. window.GarminDisconnect.showTab(tabId) — toggles which <section.tab> is
//      visible.
//   3. Wire up DOM-level click events that need to talk back to Swift (sync
//      button, activity list rows).

(function () {
    'use strict';

    window.GarminDisconnect = window.GarminDisconnect || {};

    // ---- Tab switching ---------------------------------------------------

    /// Show one tab section, hide the rest. Tab id matches the part after
    /// `tab-` in the section element's id (e.g. `overview`, `activities`).
    window.GarminDisconnect.showTab = function (tabId) {
        const sections = document.querySelectorAll('.tab');
        sections.forEach(s => s.classList.remove('active'));
        const target = document.getElementById('tab-' + tabId);
        if (target) {
            target.classList.add('active');
            // Plotly charts that were laid out while their parent section was
            // display:none come back with bogus dimensions. Force a relayout
            // pass on every chart slot inside the just-shown section.
            requestAnimationFrame(function () {
                target.querySelectorAll('.chart-slot').forEach(function (slot) {
                    if (slot && slot.data && window.Plotly) {
                        try { Plotly.Plots.resize(slot); } catch (e) { /* ignore */ }
                    }
                });
            });
        } else {
            console.warn('GarminDisconnect.showTab: no section #tab-' + tabId);
        }
    };

    // ---- Special-case renderers (non-Plotly) -----------------------------
    //
    // These are exposed via the same dispatch mechanism as the Plotly
    // renderers in charts.js so Swift only has to know about one entry point.

    /// Render the insight-cards strip into the container named in the payload
    /// (overview-insights, wellness-insights, or sleep-insights). Falls back
    /// to overview-insights for older payloads that didn't carry a container.
    /// Payload: { chart: "insight-cards", container: "...-insights", insights: [...] }
    function renderInsightCards(payload) {
        const containerId = payload.container || 'overview-insights';
        const grid = document.getElementById(containerId);
        if (!grid) return;
        grid.innerHTML = '';
        const insights = payload.insights || [];
        if (insights.length === 0) {
            grid.innerHTML = '<div class="empty-message">No insights yet — sync first.</div>';
            return;
        }
        for (const ins of insights) {
            const card = document.createElement('div');
            card.className = 'insight-card ' + (ins.direction || 'flat')
                + ' ' + (ins.severity || '');
            const arrow = ins.direction === 'up' ? '▲'
                        : ins.direction === 'down' ? '▼'
                        : '◆';
            card.innerHTML =
                '<div class="card-title">' + escapeHtml(ins.title) + '</div>' +
                '<div class="card-value">' +
                    '<span class="card-arrow">' + arrow + '</span>' +
                    escapeHtml(String(ins.value || '')) +
                '</div>' +
                (ins.sub ? '<div class="card-sub">' + escapeHtml(ins.sub) + '</div>' : '');
            grid.appendChild(card);
        }
    }

    /// Render the activity summary card — a horizontal stat band shown
    /// above the per-activity detail charts. Two-column layout: title +
    /// subtitle on the left, a flowing grid of labeled stats on the right.
    /// Payload: { chart: "activity-summary-card", title, subtitle,
    ///            rows: [{label, value}, ...] }
    function renderActivitySummaryCard(payload) {
        const slot = document.getElementById('chart-activity-summary-card');
        if (!slot) return;
        const rows = payload.rows || [];
        if (rows.length === 0) {
            slot.innerHTML = '<div class="empty-message">' +
                escapeHtml(payload.message || 'No activity data.') +
                '</div>';
            return;
        }
        let html = '<div class="summary-head">'
                 + '<div class="summary-head-title">' + escapeHtml(payload.title || '') + '</div>'
                 + '<div class="summary-head-sub">' + escapeHtml(payload.subtitle || '') + '</div>'
                 + '</div>';
        html += '<div class="summary-stats">';
        for (const r of rows) {
            html += '<div class="stat-cell">'
                  +     '<div class="stat-label">' + escapeHtml(r.label) + '</div>'
                  +     '<div class="stat-value">' + escapeHtml(String(r.value)) + '</div>'
                  + '</div>';
        }
        html += '</div>';
        slot.innerHTML = html;
        // Reveal the parent detail section if it was hidden — the summary
        // card is the first chunk loaded for a newly selected activity, so
        // make sure the section is visible by the time the GPS map paints.
        const det = document.getElementById('activity-detail-section');
        if (det) det.classList.remove('hidden');
    }

    /// Render the sleep summary card — a labels/values list inside the
    /// sleep-hero flex row. Same dispatch entry point as the Plotly charts so
    /// Swift only has to know one render call.
    /// Payload: { chart: "sleep-summary-card", title: "...", rows: [{label, value}, ...] }
    function renderSleepSummaryCard(payload) {
        const slot = document.getElementById('chart-sleep-summary-card');
        if (!slot) return;
        const rows = payload.rows || [];
        if (rows.length === 0) {
            slot.innerHTML = '<div class="empty-message">' +
                escapeHtml(payload.message || 'No sleep data yet.') +
                '</div>';
            return;
        }
        let html = '<div class="summary-title">' + escapeHtml(payload.title || 'Last night') + '</div>';
        html += '<div class="summary-rows">';
        for (const r of rows) {
            html += '<div class="summary-label">' + escapeHtml(r.label) + '</div>'
                  + '<div class="summary-value">' + escapeHtml(String(r.value)) + '</div>';
        }
        html += '</div>';
        slot.innerHTML = html;
    }

    /// Render the activity-list as a compact vertical list of cards. The
    /// Activities tab uses a sidebar layout, so we need a narrow renderer.
    ///
    /// Selection is multi: a plain click selects one row, cmd+click (ctrl on
    /// a non-Mac keyboard) adds or removes a row, and the whole selection is
    /// posted to Swift, which renders the group in the detail pane as if it
    /// were a single activity. One real outing is often several watch
    /// activities — a stop/start mid-ride, or a multi-day trip recorded one
    /// file per day — and this is how the user puts them back together.
    ///
    /// The DOM is the source of truth for what's selected: every handler reads
    /// the current `.selected` rows rather than keeping a parallel array that
    /// could drift out of sync across re-renders.
    ///
    /// Payload: { chart: "activity-list", rows: [{activity_id, start, sport, distance, duration, avg_hr, training_load}, ...], selected_activity_ids?: [int] }
    function renderActivityList(payload) {
        const slot = document.getElementById('chart-activity-list');
        if (!slot) return;
        const rows = payload.rows || [];
        if (rows.length === 0) {
            slot.innerHTML = '<div class="empty-message">No activities yet.</div>';
            return;
        }
        const selectedIds = Array.isArray(payload.selected_activity_ids)
            ? payload.selected_activity_ids.map(Number)
            : [];
        let html = '<ul class="activity-list">';
        for (const r of rows) {
            const sport = escapeHtml(r.sport || 'activity');
            const start = escapeHtml(r.start || '');
            const dist = r.distance && r.distance !== '—' ? escapeHtml(r.distance) : '';
            const dur = r.duration && r.duration !== '—' ? escapeHtml(r.duration) : '';
            const hr = r.avg_hr && r.avg_hr !== '—' ? escapeHtml(r.avg_hr) : '';
            const meta = [dist, dur, hr].filter(Boolean).join(' • ');
            const isSelected = selectedIds.indexOf(Number(r.activity_id)) !== -1;
            html += '<li class="activity-list-item' + (isSelected ? ' selected' : '') + '"'
                +     ' data-activity-id="' + r.activity_id + '">'
                + '<div class="ali-line1">'
                +     '<span class="ali-sport">' + sport + '</span>'
                +     '<span class="ali-date">' + start + '</span>'
                + '</div>'
                + (meta ? '<div class="ali-line2">' + meta + '</div>' : '')
                + '</li>';
        }
        html += '</ul>';
        html += '<div class="activity-list-hint">\u2318-click to combine activities</div>';
        slot.innerHTML = html;

        // Scroll the first selected row into view so the user lands looking
        // at the selection rather than hunting for it. `nearest` keeps the
        // sidebar's scroll position calm if the row is already visible.
        if (selectedIds.length > 0) {
            const sel = slot.querySelector('.activity-list-item.selected');
            if (sel && typeof sel.scrollIntoView === 'function') {
                sel.scrollIntoView({block: 'nearest'});
            }
        }

        /// Every currently-selected activity id, in list order (newest first).
        function currentSelection() {
            return Array.prototype.slice
                .call(slot.querySelectorAll('.activity-list-item.selected'))
                .map(function (r) { return parseInt(r.getAttribute('data-activity-id'), 10); })
                .filter(function (n) { return !isNaN(n); });
        }

        // Wire up row click → post message to Swift.
        slot.querySelectorAll('.activity-list-item').forEach(function (li) {
            li.addEventListener('click', function (ev) {
                const aid = parseInt(li.getAttribute('data-activity-id'), 10);
                if (isNaN(aid)) return;
                if (ev.metaKey || ev.ctrlKey) {
                    // Toggle — but never empty the selection. With nothing
                    // selected the detail pane has nothing to draw, and the
                    // user almost certainly meant to swap rather than clear.
                    const wasSelected = li.classList.contains('selected');
                    if (wasSelected && currentSelection().length <= 1) return;
                    li.classList.toggle('selected');
                } else {
                    slot.querySelectorAll('.activity-list-item')
                        .forEach(r => r.classList.remove('selected'));
                    li.classList.add('selected');
                }
                const ids = currentSelection();
                if (ids.length === 0) return;
                postToSwift({
                    event: 'activitySelected',
                    activity_ids: ids,
                    activity_id: ids[0],
                });
            });
        });
    }

    /// Render the recent runs table on the Sync tab.
    /// Payload: { chart: "sync-runs", rows: [{started, finished, subcommand, files, bytes, errors, exit_code}, ...] }
    function renderSyncRuns(payload) {
        const slot = document.getElementById('chart-sync-runs');
        if (!slot) return;
        const rows = payload.rows || [];
        if (rows.length === 0) {
            slot.innerHTML = '<div class="empty-message">No sync runs recorded yet.</div>';
            return;
        }
        let html = '<table class="sync-runs-table"><thead><tr>'
            + '<th>Started</th><th>Command</th><th class="right">Files</th>'
            + '<th class="right">Bytes</th><th class="right">Errors</th><th>Exit</th>'
            + '</tr></thead><tbody>';
        for (const r of rows) {
            const failed = r.exit_code !== 0 && r.exit_code !== null;
            html += '<tr' + (failed ? ' class="failed"' : '') + '>'
                + '<td>' + escapeHtml(r.started || '') + '</td>'
                + '<td>' + escapeHtml(r.subcommand || '') + '</td>'
                + '<td class="right">' + escapeHtml(r.files || '0') + '</td>'
                + '<td class="right">' + escapeHtml(r.bytes || '0') + '</td>'
                + '<td class="right">' + escapeHtml(r.errors || '0') + '</td>'
                + '<td>' + (r.exit_code === null ? '—' : r.exit_code) + '</td>'
                + '</tr>';
        }
        html += '</tbody></table>';
        slot.innerHTML = html;
    }

    /// Update the Sync tab's status banner ("Last sync: 2h ago • N new files").
    /// Payload: { chart: "sync-summary", lastSync, deviceInfo, busy }
    function renderSyncSummary(payload) {
        const lastEl = document.getElementById('sync-last-summary');
        const devEl = document.getElementById('sync-device-info');
        const btn = document.getElementById('sync-now-btn');
        if (lastEl) lastEl.textContent = payload.lastSync || 'Last sync: never';
        if (devEl) devEl.textContent = payload.deviceInfo || '';
        if (btn) {
            btn.disabled = !!payload.busy;
            btn.textContent = payload.busy ? 'Syncing…' : 'Pull now';
        }
    }

    // ---- Empty-state placeholder ----------------------------------------

    /// Hide a chart slot outright: no card, no message, no space. Used for a
    /// control that simply doesn't apply to the current selection, where a
    /// note explaining the absence would cost more room than the control
    /// (e.g. trim under a multi-activity selection, #261).
    ///
    /// Slots usually sit alone in a `.chart-grid` row that carries its own
    /// gap and bottom margin, so hiding only the slot would leave a visible
    /// hole. `syncGridVisibility` hides the row too once every slot in it is
    /// hidden, and brings it back as soon as one isn't.
    function renderHidden(chartId) {
        const el = document.getElementById('chart-' + chartId);
        if (!el) return;
        if (window.Plotly && el.data) {
            try { Plotly.purge(el); } catch (e) { /* ignore */ }
        }
        el.innerHTML = '';
        el.classList.add('hidden');
        syncGridVisibility(el);
    }

    /// Re-show a slot hidden by a previous `renderHidden`. Called on every
    /// non-hidden payload, so the slot reappears the moment it has content.
    function unhideSlot(chartId) {
        const el = document.getElementById('chart-' + chartId);
        if (!el || !el.classList.contains('hidden')) return;
        el.classList.remove('hidden');
        syncGridVisibility(el);
    }

    /// Hide/show a slot's `.chart-grid` row to match its children: hidden iff
    /// every element child is hidden. Rows that aren't `.chart-grid` (the
    /// activity summary card, the sidebar) are left alone.
    function syncGridVisibility(el) {
        const row = el.parentElement;
        if (!row || !row.classList.contains('chart-grid')) return;
        const anyVisible = Array.prototype.some.call(
            row.children, function (c) { return !c.classList.contains('hidden'); }
        );
        row.classList.toggle('hidden', !anyVisible);
    }

    function renderEmpty(chartId, message) {
        const slotId = 'chart-' + chartId;
        let el = document.getElementById(slotId);
        if (!el) return;
        if (window.Plotly && el.data) {
            try { Plotly.purge(el); } catch (e) { /* ignore */ }
        }
        el.innerHTML = '';
        const inner = document.createElement('div');
        inner.className = 'empty-message';
        inner.textContent = message || 'No data yet.';
        el.appendChild(inner);
    }

    // ---- Dispatch entry point -------------------------------------------

    window.GarminDisconnect.render = function (payload) {
        if (!payload || typeof payload !== 'object') {
            console.error('GarminDisconnect.render: invalid payload', payload);
            return;
        }
        const chartId = payload.chart;
        if (!chartId) {
            console.error('GarminDisconnect.render: payload missing chart id', payload);
            return;
        }
        // If the payload describes an interval picker, render the strip first
        // (so it appears above the chart). The empty-state and Plotly paths
        // both clear the slot's children, so we install the controls in a
        // separate sibling element keyed off the slot's parent.
        if (payload.window) {
            renderWindowControls(chartId, payload.window);
        } else {
            removeWindowControls(chartId);
        }

        if (payload.chart_hidden) {
            renderHidden(chartId);
            return;
        }
        unhideSlot(chartId);

        if (payload.chart_empty) {
            renderEmpty(chartId, payload.message);
            return;
        }
        // Special-case renderers (non-Plotly).
        if (chartId === 'insight-cards') return renderInsightCards(payload);
        if (chartId === 'activity-list') return renderActivityList(payload);
        if (chartId === 'sync-runs')      return renderSyncRuns(payload);
        if (chartId === 'sync-summary')   return renderSyncSummary(payload);
        if (chartId === 'sleep-summary-card') return renderSleepSummaryCard(payload);
        if (chartId === 'activity-summary-card') return renderActivitySummaryCard(payload);

        // Plotly renderers.
        const renderers = window.GarminDisconnect.renderers || {};
        const fn = renderers[chartId];
        if (typeof fn !== 'function') {
            console.error('GarminDisconnect.render: no renderer for', chartId);
            return;
        }
        fn(payload);
    };

    // ---- Interval picker (per-chart "◀ Day | Week | Month | Year ▶") -----

    function controlsId(chartId) { return 'window-' + chartId; }

    /// Wrap the chart slot in a `.chart-card` parent the first time we see
    /// a windowed payload for that chart, so the interval-picker strip can
    /// live as a sibling of the slot instead of inside it. (Plotly's
    /// `Plotly.newPlot(el, ...)` REPLACES the contents of `el`, so any
    /// controls living inside the slot get wiped on every redraw.)
    /// Returns the wrapper element so the caller can attach the controls.
    function ensureChartWrapper(chartId) {
        const slot = document.getElementById('chart-' + chartId);
        if (!slot) return null;
        const parent = slot.parentElement;
        if (parent && parent.classList.contains('chart-card')) return parent;
        const card = document.createElement('div');
        card.className = 'chart-card';
        parent.insertBefore(card, slot);
        card.appendChild(slot);
        return card;
    }

    /// Inject (or update in place) the interval-picker strip for a chart.
    /// The strip lives in a `.chart-card` wrapper above the chart slot so
    /// Plotly's redraws don't clobber it.
    function renderWindowControls(chartId, w) {
        const slot = document.getElementById('chart-' + chartId);
        if (!slot) return;
        const card = ensureChartWrapper(chartId);
        if (!card) return;
        let bar = document.getElementById(controlsId(chartId));
        if (!bar) {
            bar = document.createElement('div');
            bar.id = controlsId(chartId);
            bar.className = 'chart-window-controls';
            card.insertBefore(bar, slot);
        }
        const intervals = w.intervals || [];
        const labels = w.labels || intervals;
        const selected = w.selected || '';
        const canBack = w.canShiftBack === true;
        const canForward = w.canShiftForward === true;
        let html = '';
        html += '<button class="window-arrow" data-delta="-1"' +
                (canBack ? '' : ' disabled') + '>◀</button>';
        html += '<div class="window-tabs">';
        for (let i = 0; i < intervals.length; i++) {
            const cls = intervals[i] === selected ? 'window-tab active' : 'window-tab';
            html += '<button class="' + cls + '" data-interval="' +
                    escapeHtml(intervals[i]) + '">' + escapeHtml(labels[i]) +
                    '</button>';
        }
        html += '</div>';
        html += '<button class="window-arrow" data-delta="1"' +
                (canForward ? '' : ' disabled') + '>▶</button>';
        html += '<span class="window-label">' + escapeHtml(w.label || '') + '</span>';
        bar.innerHTML = html;

        // Wire clicks. Each event posts back to Swift, which mutates
        // ChartWindowStore and re-renders the chart.
        bar.querySelectorAll('.window-tab').forEach(function (btn) {
            btn.addEventListener('click', function () {
                postToSwift({
                    event: 'chartWindowChanged',
                    chart: chartId,
                    interval: btn.getAttribute('data-interval'),
                });
            });
        });
        bar.querySelectorAll('.window-arrow').forEach(function (btn) {
            if (btn.disabled) return;
            btn.addEventListener('click', function () {
                postToSwift({
                    event: 'chartWindowShifted',
                    chart: chartId,
                    delta: parseInt(btn.getAttribute('data-delta'), 10),
                });
            });
        });
    }

    /// Remove the interval-picker strip from a chart slot — used when the
    /// payload no longer carries a `window` (e.g. on the empty path or when
    /// a chart loses its windowed-loader treatment).
    function removeWindowControls(chartId) {
        const bar = document.getElementById(controlsId(chartId));
        if (bar && bar.parentElement) bar.parentElement.removeChild(bar);
    }

    // ---- DOM-level wiring (sync button etc.) ----------------------------

    document.addEventListener('click', function (e) {
        const t = e.target;
        if (t && t.id === 'sync-now-btn') {
            postToSwift({event: 'syncRequested'});
        }
    });

    // ---- Helpers --------------------------------------------------------

    function postToSwift(msg) {
        try {
            window.webkit.messageHandlers.garminDisconnect.postMessage(msg);
        } catch (e) {
            console.error('postToSwift failed:', e, msg);
        }
    }

    function escapeHtml(s) {
        if (s == null) return '';
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    // Tell Swift the page is ready.
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.garminDisconnect) {
        window.webkit.messageHandlers.garminDisconnect.postMessage({event: 'pageReady', ts: Date.now()});
    }
})();

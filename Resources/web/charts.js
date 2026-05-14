// charts.js — one Plotly renderer per chart-id.
//
// Each renderer takes a payload from PlotlyEncoder.swift and calls
// `Plotly.newPlot(slotEl, payload.data, payload.layout, payload.config)`. The
// per-chart functions are kept dumb on purpose: all data shaping happens
// Swift-side, so JS just hands the trace + layout straight to Plotly.
//
// The dispatch table at the bottom maps chart-id strings to renderer
// functions. bootstrap.js's window.GarminDisconnect.render() looks up the id
// here. Renderers for non-Plotly UI (insight cards, activity list, sync
// runs/summary) live in bootstrap.js, not here.

(function () {
    'use strict';

    // ---- Helpers --------------------------------------------------------

    function slot(chartId) {
        return document.getElementById('chart-' + chartId);
    }

    function plot(chartId, payload) {
        const el = slot(chartId);
        if (!el) {
            console.warn('charts.js: no slot for', chartId);
            return;
        }
        Plotly.newPlot(el, payload.data, payload.layout, payload.config);
        attachClickBridge(el, chartId);
    }

    function attachClickBridge(el, chartId) {
        if (!el || !el.on) return;
        el.on('plotly_click', function (eventData) {
            try {
                const point = eventData && eventData.points && eventData.points[0];
                if (!point) return;
                window.webkit.messageHandlers.garminDisconnect.postMessage({
                    event: 'chartClicked',
                    chart: chartId,
                    x: point.x, y: point.y, z: point.z,
                    customdata: point.customdata,
                });
            } catch (e) {
                console.error('click bridge failed:', e);
            }
        });
    }

    // ---- Renderers ------------------------------------------------------

    function renderDailyStepsBar(p)             { plot('daily-steps-bar', p); }
    function renderRestingHRTrendline(p)        { plot('resting-hr-trendline', p); }
    function renderBodyBatteryGauge(p)          { plot('body-battery-gauge', p); }
    function renderRecentActivitiesTimeline(p)  { plot('recent-activities-timeline', p); }
    function renderWeeklyDistanceBar(p)         { plot('weekly-distance-bar', p); }
    function renderActivityPaceAltitude(p) {
        plot('activity-pace-altitude', p);
        installMetricToggles();
    }

    /// Wire the four metric checkboxes above the activity chart to
    /// Plotly.restyle (trace visibility) and Plotly.relayout (axis
    /// visibility). Re-runs after every renderActivityPaceAltitude — the
    /// chart is purged and rebuilt by newPlot, so checkbox state is
    /// authoritative and pushed back into Plotly each render.
    function installMetricToggles() {
        const el = slot('activity-pace-altitude');
        const bar = document.getElementById('activity-metric-toggles');
        if (!el || !bar) return;
        const boxes = bar.querySelectorAll('input[type="checkbox"]');
        boxes.forEach(function (cb) {
            // Push current checkbox state into the chart on every render —
            // covers the case where the user toggled a box, then switched
            // activities, and the new render came in with default visibility.
            applyToggle(cb);
            // Remove any prior listener (cloneNode is the cheapest way) and
            // attach a fresh one bound to this render's chart element.
            const fresh = cb.cloneNode(true);
            cb.parentNode.replaceChild(fresh, cb);
            fresh.addEventListener('change', function () { applyToggle(fresh); });
        });

        function applyToggle(cb) {
            const traceIdx = parseInt(cb.dataset.trace, 10);
            const axis = cb.dataset.axis;
            const visible = !!cb.checked;
            try {
                Plotly.restyle(el, { visible: visible }, [traceIdx]);
                Plotly.relayout(el, { [axis + '.visible']: visible });
            } catch (e) {
                console.error('metric toggle failed:', e);
            }
        }
    }
    function renderActivityHRZones(p)           { plot('activity-hr-zones', p); }
    function renderActivityGPSMap(p) {
        plot('activity-gps-map', p);
        // Stash the trim helper data so the trim-controls slot can drive
        // live polyline restyles during handle drag without needing a Swift
        // round-trip per pointermove tick.
        const el = slot('activity-gps-map');
        if (el && p && p.trim_targets) {
            el._gpdTrimTargets = p.trim_targets;
        }
        installGPSMapHandlers();
    }
    function renderActivityTrimControls(p) {
        installTrimControls(p);
    }

    /// Install GPS-map-specific event handlers: the corner hover legend,
    /// plus a force-redraw on every updatemenu button click.
    ///
    /// Hover legend: Plotly's newPlot() purges the chart slot's children,
    /// so we always rebuild the overlay element after each render. The
    /// overlay is hidden by default and only appears while the cursor is
    /// actually hovering a point on the trail (plain trace) or one of the
    /// pause / start / end markers — `plotly_unhover` hides it again as
    /// soon as the cursor leaves. Plain trace uses `hoverinfo: "none"` so
    /// events fire without showing Plotly's default tooltip; marker traces
    /// expose their label via `hovertext` instead of `text`.
    ///
    /// Force-redraw on button click: Plotly's restyle of `visible` on
    /// scattermap (MapLibre) traces sometimes leaves the canvas stale —
    /// the trace's `visible` flag flips, but the GL layer doesn't repaint
    /// until something else triggers a redraw. The user-visible symptom
    /// is that the color-by tabs need two clicks before the rainbow
    /// actually shows up. Calling Plotly.redraw on `plotly_buttonclicked`
    /// (deferred via setTimeout(0) so it runs *after* the button's own
    /// restyle/relayout has completed) forces the GL layer to repaint
    /// every time.
    function installGPSMapHandlers() {
        const el = slot('activity-gps-map');
        if (!el || !el.on) return;
        const existing = el.querySelector('.gps-hover-legend');
        if (existing) existing.remove();
        const overlay = document.createElement('div');
        overlay.className = 'gps-hover-legend hidden';
        el.appendChild(overlay);

        // Per-install state: which button index is active in each menu.
        // The Swift side sets every menu's `active: 0` initially, so the
        // map is empty until the user clicks something — and an empty
        // entry falls back to index 0 in `applyActive` below.
        // This is reset on every newPlot because installGPSMapHandlers
        // is re-called and a fresh closure is built. Plotly.purge (run
        // by newPlot) also clears any old listeners, so re-binding here
        // doesn't stack handlers.
        const activeByMenu = {};

        el.on('plotly_hover', function (eventData) {
            const pt = eventData && eventData.points && eventData.points[0];
            if (!pt) return;
            // hovertext (set on pause / start / end marker traces) wins over
            // text (set on the plain line trace) when both are present.
            const label = pt.hovertext != null ? pt.hovertext : pt.text;
            if (label == null) return;
            overlay.innerHTML = String(label);
            overlay.classList.remove('hidden');
        });
        el.on('plotly_unhover', function () {
            overlay.classList.add('hidden');
        });

        el.on('plotly_buttonclicked', function (eventData) {
            // Track the click directly from the event payload — this is
            // the source of truth and doesn't depend on _fullLayout
            // surviving Plotly.redraw.
            if (eventData && eventData.menu && eventData.button) {
                const mIdx = eventData.menu._index;
                const bIdx = eventData.button._index;
                if (typeof mIdx === 'number' && typeof bIdx === 'number') {
                    activeByMenu[mIdx] = bIdx;
                }
            }
            // Defer one tick so Plotly has finished applying the button's
            // own restyle/relayout, then force a canvas redraw (works
            // around the "two clicks for color-by" scattermap quirk) and
            // re-apply our active class on the freshly-rendered DOM.
            // Also re-fix tile overzooming because tile-style button
            // clicks trigger a relayout that recreates MapLibre layers
            // with Plotly's maxzoom applied again.
            setTimeout(function () {
                Plotly.redraw(el);
                applyActive();
                fixTileOverzoom(el);
            }, 0);
        });

        // Re-apply the active class after every render — newPlot,
        // restyle, relayout, redraw all emit plotly_afterplot.
        el.on('plotly_afterplot', function () {
            applyActive();
            fixTileOverzoom(el);
        });

        // Initial pass for the first newPlot. plotly_afterplot may fire
        // synchronously inside newPlot before this listener is bound,
        // so we'd miss it without an explicit call. Defer to next tick
        // so the button DOM / MapLibre map have settled.
        setTimeout(function () {
            applyActive();
            fixTileOverzoom(el);
            installGPSScaleBar(el);
        }, 100);

        /// Apply the .gpd-active-button class to the active button in
        /// each updatemenu, based on `activeByMenu` state. Robust to
        /// Plotly's container DOM by grouping buttons by their parent
        /// (each menu's buttons share a parent `<g>`).
        function applyActive() {
            const allButtons = el.querySelectorAll('g.updatemenu-button');
            if (!allButtons.length) return;
            const groups = [];
            const parentToGroup = new Map();
            allButtons.forEach(function (btn) {
                const parent = btn.parentNode;
                let g = parentToGroup.get(parent);
                if (!g) {
                    g = [];
                    parentToGroup.set(parent, g);
                    groups.push(g);
                }
                g.push(btn);
            });
            groups.forEach(function (buttons, mIdx) {
                const activeIdx = typeof activeByMenu[mIdx] === 'number'
                    ? activeByMenu[mIdx]
                    : 0;
                buttons.forEach(function (btn, bIdx) {
                    btn.classList.toggle('gpd-active-button', bIdx === activeIdx);
                });
            });
        }
    }

    /// Remove the MapLibre LAYER maxzoom that Plotly copies from our tile
    /// config. Plotly applies `maxzoom` from the layer config to BOTH the
    /// MapLibre source (which limits tile requests and enables overzooming)
    /// AND the MapLibre layer (which hides the layer entirely beyond that
    /// zoom). The source maxzoom is correct — it tells MapLibre to reuse
    /// the highest-zoom tiles at deeper zoom levels. But the layer maxzoom
    /// makes the entire layer vanish when the user zooms past the
    /// provider's limit. Removing it lets tiles overzoom (pixelated but
    /// visible) instead of disappearing.
    function fixTileOverzoom(el) {
        try {
            var map = el._fullLayout.map._subplot.map;
            var style = map.getStyle();
            if (!style || !style.layers) return;
            style.layers.forEach(function (layer) {
                if (layer.type === 'raster' && layer.maxzoom != null && layer.maxzoom < 24) {
                    map.setLayerZoomRange(layer.id, layer.minzoom || 0, 24);
                }
            });
        } catch (e) {
            // MapLibre map not ready yet or internal API changed.
        }
    }

    /// Custom scale bar overlay for the GPS map. Plotly's scattermap
    /// doesn't expose MapLibre's built-in ScaleControl, so we compute the
    /// scale ourselves from zoom + center latitude and render it as an
    /// HTML overlay in the bottom-right corner of the chart slot.
    ///
    /// The bar auto-resizes to a "nice" round distance (5 m, 10 m, …
    /// 50 km) that fits between ~50–150 px wide. It updates live on
    /// every zoom/pan via MapLibre's own events (no Plotly round-trip
    /// needed), with plotly_relayout/afterplot as fallbacks.
    function installGPSScaleBar(el) {
        var old = el.querySelector('.gps-scale-bar');
        if (old) old.remove();

        var bar = document.createElement('div');
        bar.className = 'gps-scale-bar';
        bar.innerHTML =
            '<div class="gps-scale-line"></div>' +
            '<span class="gps-scale-label"></span>';
        el.appendChild(bar);

        var line = bar.querySelector('.gps-scale-line');
        var label = bar.querySelector('.gps-scale-label');

        var NICE = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000,
                    2000, 5000, 10000, 20000, 50000, 100000];

        function update() {
            var zoom, lat;
            try {
                var map = el._fullLayout.map._subplot.map;
                zoom = map.getZoom();
                lat = map.getCenter().lat;
            } catch (e) {
                try {
                    zoom = el._fullLayout.map.zoom;
                    lat = el._fullLayout.map.center.lat;
                } catch (e2) { return; }
            }
            if (zoom == null || lat == null) return;

            // Ground resolution at this zoom & latitude (meters per pixel).
            var mpp = (40075016.686 * Math.cos(lat * Math.PI / 180)) /
                      (256 * Math.pow(2, zoom));

            // Pick the largest "nice" distance that renders between 50–150 px.
            var bestM = NICE[0];
            for (var i = 0; i < NICE.length; i++) {
                var px = NICE[i] / mpp;
                if (px > 150) break;
                if (px >= 50) { bestM = NICE[i]; break; }
                bestM = NICE[i];
            }

            var barPx = Math.max(20, Math.min(200, Math.round(bestM / mpp)));
            line.style.width = barPx + 'px';
            label.textContent = bestM >= 1000
                ? (bestM / 1000) + ' km'
                : bestM + ' m';
        }

        // Bind directly to MapLibre for real-time zoom/pan updates.
        try {
            var map = el._fullLayout.map._subplot.map;
            map.on('zoomend', update);
            map.on('moveend', update);
        } catch (e) {}

        // Plotly-level fallbacks for the initial render and any
        // programmatic relayouts.
        el.on('plotly_relayout', update);
        el.on('plotly_afterplot', update);
        update();
    }
    /// Build the trim-controls timeline below the GPS map. Pure DOM (no
    /// Plotly): a flex row of segment blocks separated by pause gaps, each
    /// segment carrying two draggable handles. Drag deltas drive a live
    /// Plotly.restyle on the GPS map (using lat/lon arrays stashed by
    /// renderActivityGPSMap as `el._gpdTrimTargets`). On pointerup the JS
    /// posts `activityTrimChanged` to Swift, which persists and re-renders
    /// the full activity-detail set with the trim applied.
    ///
    /// State model: `segState[i]` carries `{segStartS, segEndS, keptStart,
    /// keptEnd}`. Both handles are clamped to [segStartS, segEndS]. A
    /// segment is "collapsed" iff keptStart > keptEnd — the .trim-keep
    /// overlay vanishes and the segment dims. The persisted trim ranges are
    /// the non-collapsed segments' kept windows, in order.
    function installTrimControls(p) {
        const el = slot('activity-trim-controls');
        if (!el) return;
        el.innerHTML = '';

        // Empty-state: bail on any malformed payload.
        if (!p || !Array.isArray(p.segments) || p.segments.length === 0) {
            el.classList.add('empty');
            el.textContent = (p && p.message) ? p.message : 'No timeline available.';
            return;
        }
        el.classList.remove('empty');

        const activityId    = p.activity_id;
        const segments      = p.segments;
        const samples       = Array.isArray(p.samples) ? p.samples : [];
        const totalElapsedS = p.total_elapsed_s;
        const firstElapsedS = p.first_elapsed_s;
        const trim          = p.trim || null;

        // ---- Resolve initial per-segment kept ranges from saved trim ----
        // No trim → every segment is fully kept. With a trim, find each
        // segment's intersection with the union of TrimRanges; no
        // intersection → segment starts collapsed.
        const segState = segments.map(function (seg) {
            let keptStart, keptEnd;
            if (!trim || !Array.isArray(trim.ranges) || trim.ranges.length === 0) {
                keptStart = seg.startS;
                keptEnd   = seg.endS;
            } else {
                let foundStart = null, foundEnd = null;
                for (let r = 0; r < trim.ranges.length; r++) {
                    const rr = trim.ranges[r];
                    const s = Math.max(seg.startS, rr.startS);
                    const e = Math.min(seg.endS,   rr.endS);
                    if (s <= e) {
                        foundStart = (foundStart == null) ? s : Math.min(foundStart, s);
                        foundEnd   = (foundEnd   == null) ? e : Math.max(foundEnd,   e);
                    }
                }
                if (foundStart == null) {
                    // Collapsed: keptStart > keptEnd means "no kept window".
                    keptStart = seg.endS;
                    keptEnd   = seg.startS;
                } else {
                    keptStart = foundStart;
                    keptEnd   = foundEnd;
                }
            }
            return {
                segStartS: seg.startS,
                segEndS:   seg.endS,
                keptStart: keptStart,
                keptEnd:   keptEnd,
            };
        });

        // ---- Build header (title + reset) ----
        const header = document.createElement('div');
        header.className = 'trim-header';
        const title = document.createElement('span');
        title.className = 'trim-title';
        title.textContent = 'Trim';
        const resetBtn = document.createElement('button');
        resetBtn.className = 'trim-reset';
        resetBtn.textContent = 'Reset';
        // Reset is a no-op if the activity is already untrimmed (no auto, no
        // manual). Don't fight the user with a disabled button — let them
        // click it; the message goes to Swift, which DELETEs the (possibly
        // missing) row and re-renders.
        resetBtn.addEventListener('click', function () {
            try {
                window.webkit.messageHandlers.garminDisconnect.postMessage({
                    event: 'activityTrimReset',
                    activity_id: activityId,
                });
            } catch (e) {
                console.error('trim reset post failed:', e);
            }
        });
        header.appendChild(title);
        header.appendChild(resetBtn);
        el.appendChild(header);

        // ---- Build the flex-row timeline ----
        // Segments and pause gaps share a single flex row; each child sets
        // flex-grow proportional to its elapsed-second span so real time is
        // preserved without manual scaling.
        const timeline = document.createElement('div');
        timeline.className = 'trim-timeline';
        el.appendChild(timeline);

        const segmentEls = [];
        const keepEls    = [];
        const startHandles = [];
        const endHandles   = [];

        for (let i = 0; i < segments.length; i++) {
            const seg = segments[i];
            const segLen = Math.max(1, seg.endS - seg.startS);

            const segEl = document.createElement('div');
            segEl.className = 'trim-segment';
            segEl.style.flexGrow = String(segLen);
            segEl.style.flexBasis = '0';
            segEl.dataset.segIdx = String(i);

            const keepEl = document.createElement('div');
            keepEl.className = 'trim-keep';
            segEl.appendChild(keepEl);

            const startHandle = document.createElement('div');
            startHandle.className = 'trim-handle';
            startHandle.dataset.edge = 'start';
            startHandle.dataset.segIdx = String(i);
            segEl.appendChild(startHandle);

            const endHandle = document.createElement('div');
            endHandle.className = 'trim-handle';
            endHandle.dataset.edge = 'end';
            endHandle.dataset.segIdx = String(i);
            segEl.appendChild(endHandle);

            timeline.appendChild(segEl);
            segmentEls.push(segEl);
            keepEls.push(keepEl);
            startHandles.push(startHandle);
            endHandles.push(endHandle);

            // Insert pause gap to the next segment (if any).
            if (i < segments.length - 1) {
                const gapLen = Math.max(1, segments[i + 1].startS - seg.endS);
                const gapEl = document.createElement('div');
                gapEl.className = 'trim-gap';
                gapEl.style.flexGrow = String(gapLen);
                gapEl.style.flexBasis = '0';
                timeline.appendChild(gapEl);
            }
        }

        // Tooltip element shared by all handles.
        const tooltip = document.createElement('div');
        tooltip.className = 'trim-tooltip hidden';
        el.appendChild(tooltip);

        // Note line below.
        const noteEl = document.createElement('div');
        noteEl.className = 'trim-note hidden';
        if (trim && trim.auto && trim.reason) {
            noteEl.textContent = trim.reason;
            noteEl.classList.remove('hidden');
        }
        el.appendChild(noteEl);

        // ---- Render kept-window overlays from current segState ----
        function renderSegStateVisuals() {
            for (let i = 0; i < segState.length; i++) {
                const s = segState[i];
                const segLen = Math.max(1, s.segEndS - s.segStartS);
                const collapsed = s.keptStart > s.keptEnd;
                segmentEls[i].classList.toggle('collapsed', collapsed);
                if (collapsed) {
                    keepEls[i].style.left = '0%';
                    keepEls[i].style.width = '0%';
                } else {
                    const leftPct  = ((s.keptStart - s.segStartS) / segLen) * 100;
                    const widthPct = ((s.keptEnd   - s.keptStart) / segLen) * 100;
                    keepEls[i].style.left  = leftPct  + '%';
                    keepEls[i].style.width = widthPct + '%';
                }
                // Position handles. Each handle's `left` is a % within the
                // segment block. `margin-left: -7px` in CSS centers the
                // 14px-wide hit area on that point.
                const startPct = collapsed
                    ? 100 * (s.keptStart - s.segStartS) / segLen
                    : 100 * (s.keptStart - s.segStartS) / segLen;
                const endPct   = collapsed
                    ? 100 * (s.keptEnd   - s.segStartS) / segLen
                    : 100 * (s.keptEnd   - s.segStartS) / segLen;
                startHandles[i].style.left = Math.max(0, Math.min(100, startPct)) + '%';
                endHandles[i].style.left   = Math.max(0, Math.min(100, endPct))   + '%';
            }
        }
        renderSegStateVisuals();

        // ---- Live polyline restyle on the GPS map ----
        const mapEl = slot('activity-gps-map');
        const trimTargets = mapEl ? mapEl._gpdTrimTargets : null;

        function buildKeptLatLon() {
            if (!trimTargets || !Array.isArray(trimTargets.samples)) return null;
            const samp = trimTargets.samples;
            const lat = new Array(samp.length);
            const lon = new Array(samp.length);
            let firstKept = -1, lastKept = -1;
            for (let k = 0; k < samp.length; k++) {
                const e = samp[k].elapsedS;
                let kept = false;
                for (let i = 0; i < segState.length; i++) {
                    const s = segState[i];
                    if (s.keptStart > s.keptEnd) continue;
                    if (e >= s.keptStart && e <= s.keptEnd) { kept = true; break; }
                }
                if (kept) {
                    lat[k] = samp[k].lat;
                    lon[k] = samp[k].lon;
                    if (firstKept < 0) firstKept = k;
                    lastKept = k;
                } else {
                    lat[k] = null;
                    lon[k] = null;
                }
            }
            return { lat: lat, lon: lon, firstKept: firstKept, lastKept: lastKept, samp: samp };
        }

        function pushPreviewToMap() {
            if (!mapEl || !trimTargets) return;
            const k = buildKeptLatLon();
            if (!k) return;
            try {
                Plotly.restyle(mapEl, {
                    lat: [k.lat, k.lat],
                    lon: [k.lon, k.lon],
                }, [trimTargets.outline_idx, trimTargets.plain_idx]);
                if (k.firstKept >= 0) {
                    Plotly.restyle(mapEl, {
                        lat: [[k.samp[k.firstKept].lat]],
                        lon: [[k.samp[k.firstKept].lon]],
                    }, [trimTargets.start_idx]);
                    Plotly.restyle(mapEl, {
                        lat: [[k.samp[k.lastKept].lat]],
                        lon: [[k.samp[k.lastKept].lon]],
                    }, [trimTargets.end_idx]);
                }
            } catch (e) {
                console.error('trim preview restyle failed:', e);
            }
        }

        // ---- Drag handlers ----
        function fmtDuration(s) {
            s = Math.max(0, Math.round(s));
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            const sec = s % 60;
            return (h > 0 ? (h + ':' + String(m).padStart(2, '0')) : String(m))
                + ':' + String(sec).padStart(2, '0');
        }
        function findSampleAt(elapsedS) {
            // Linear scan is fine — samples is at most ~10k, and drag events
            // come in at most every few ms; binary search is overkill.
            if (samples.length === 0) return null;
            let best = samples[0], bestDiff = Math.abs(samples[0].elapsedS - elapsedS);
            for (let k = 1; k < samples.length; k++) {
                const d = Math.abs(samples[k].elapsedS - elapsedS);
                if (d < bestDiff) { bestDiff = d; best = samples[k]; }
            }
            return best;
        }
        function fmtClock(ts) {
            // ts is an ISO-8601 UTC string. Show local-time HH:MM:SS so the
            // user can match it to landmarks in their day. Fallback to the
            // raw string if Date parsing chokes.
            try {
                const d = new Date(ts);
                if (isNaN(d.getTime())) return ts;
                return d.toLocaleTimeString([], {
                    hour: '2-digit', minute: '2-digit', second: '2-digit',
                });
            } catch (e) { return ts; }
        }
        function showTooltipFor(handleEl, elapsedS) {
            const slotRect = el.getBoundingClientRect();
            const handleRect = handleEl.getBoundingClientRect();
            const cx = handleRect.left + handleRect.width / 2 - slotRect.left;
            const cy = handleRect.top - slotRect.top;
            const samp = findSampleAt(elapsedS);
            tooltip.style.left = cx + 'px';
            tooltip.style.top  = cy + 'px';
            tooltip.innerHTML =
                't+' + fmtDuration(elapsedS) +
                (samp ? '<div class="trim-tooltip-clock">' + fmtClock(samp.ts) + '</div>' : '');
            tooltip.classList.remove('hidden');
        }
        function hideTooltip() {
            tooltip.classList.add('hidden');
        }

        let drag = null;
        function attachHandle(handleEl) {
            handleEl.addEventListener('pointerdown', function (ev) {
                ev.preventDefault();
                handleEl.setPointerCapture(ev.pointerId);
                handleEl.classList.add('dragging');
                const segIdx = parseInt(handleEl.dataset.segIdx, 10);
                drag = {
                    handleEl: handleEl,
                    segIdx: segIdx,
                    edge:   handleEl.dataset.edge,
                    pointerId: ev.pointerId,
                };
                onDragMove(ev);
            });
            handleEl.addEventListener('pointermove', function (ev) {
                if (!drag || drag.pointerId !== ev.pointerId) return;
                onDragMove(ev);
            });
            function endDrag(ev) {
                if (!drag || drag.pointerId !== ev.pointerId) return;
                handleEl.classList.remove('dragging');
                try { handleEl.releasePointerCapture(ev.pointerId); } catch (e) {}
                drag = null;
                hideTooltip();
                postTrimChange();
            }
            handleEl.addEventListener('pointerup', endDrag);
            handleEl.addEventListener('pointercancel', endDrag);
        }
        function onDragMove(ev) {
            if (!drag) return;
            const segIdx = drag.segIdx;
            const segEl = segmentEls[segIdx];
            const segRect = segEl.getBoundingClientRect();
            if (segRect.width <= 0) return;
            const s = segState[segIdx];
            const segLen = s.segEndS - s.segStartS;
            // Clamp pointer x to [0, segRect.width], then convert to
            // elapsed-second within the segment.
            const relX = Math.max(0, Math.min(segRect.width, ev.clientX - segRect.left));
            let elapsedS = s.segStartS + Math.round((relX / segRect.width) * segLen);
            elapsedS = Math.max(s.segStartS, Math.min(s.segEndS, elapsedS));
            if (drag.edge === 'start') {
                s.keptStart = elapsedS;
            } else {
                s.keptEnd = elapsedS;
            }
            renderSegStateVisuals();
            showTooltipFor(drag.handleEl, elapsedS);
            pushPreviewToMap();
        }
        for (let i = 0; i < startHandles.length; i++) {
            attachHandle(startHandles[i]);
            attachHandle(endHandles[i]);
        }

        // ---- Commit on pointerup ----
        function postTrimChange() {
            const ranges = [];
            for (let i = 0; i < segState.length; i++) {
                const s = segState[i];
                if (s.keptStart > s.keptEnd) continue;  // collapsed
                ranges.push({ startS: s.keptStart, endS: s.keptEnd });
            }
            try {
                window.webkit.messageHandlers.garminDisconnect.postMessage({
                    event: 'activityTrimChanged',
                    activity_id: activityId,
                    ranges: ranges,
                });
            } catch (e) {
                console.error('trim change post failed:', e);
            }
        }

        // Suppress unused-var warnings for the few values we read but don't
        // need to keep references to in this scope.
        void totalElapsedS; void firstElapsedS;
    }
    function renderStressBodyBatteryTS(p)       { plot('stress-body-battery-ts', p); }
    function renderDailyIntensityMinutesBar(p)  { plot('daily-intensity-minutes-bar', p); }
    function renderStepsHourlyHeatmap(p)        { plot('steps-hourly-heatmap', p); }
    function renderHrvDailyTrend(p)             { plot('hrv-daily-trend', p); }
    function renderHrRangeBand(p)               { plot('hr-range-band', p); }
    function renderDailyStepsDistanceCombo(p)   { plot('daily-steps-distance-combo', p); }
    function renderRespirationSpo2TS(p)         { plot('respiration-spo2-ts', p); }
    function renderSleepHypnogram(p) {
        plot('sleep-hypnogram', p);
        // Show the parent activity-detail-section if it was hidden.
        const det = document.getElementById('activity-detail-section');
        if (det) det.classList.remove('hidden');
    }
    function renderSleepStageDonut(p)           { plot('sleep-stage-donut', p); }
    function renderSleepScoreTrend(p)           { plot('sleep-score-trend', p); }
    function renderSleepDurationBar(p)          { plot('sleep-duration-bar', p); }
    function renderSleepStageStacked(p)         { plot('sleep-stage-stacked', p); }
    function renderSleepBedWakeScatter(p)       { plot('sleep-bed-wake-scatter', p); }
    function renderSleepRegularityHeatmap(p) {
        plot('sleep-regularity-heatmap', p);
        // Click handling is dispatched Swift-side via the generic
        // `chartClicked` event installed by attachClickBridge. The cells
        // carry customdata = sleep_id so MainWindowController can swap the
        // hero card to the picked night.
    }

    /// Reveal the activity-detail section once an activity is selected.
    function revealActivityDetail() {
        const det = document.getElementById('activity-detail-section');
        if (det) det.classList.remove('hidden');
    }

    // Wrap the per-activity Plotly renderers so they reveal the detail section.
    function renderActivityPaceAltitudeAndReveal(p) {
        revealActivityDetail();
        renderActivityPaceAltitude(p);
    }
    function renderActivityHRZonesAndReveal(p) {
        revealActivityDetail();
        renderActivityHRZones(p);
    }
    function renderActivityGPSMapAndReveal(p) {
        revealActivityDetail();
        renderActivityGPSMap(p);
    }

    // ---- Dispatch -------------------------------------------------------

    window.GarminDisconnect = window.GarminDisconnect || {};
    window.GarminDisconnect.renderers = {
        // Overview
        'daily-steps-bar':              renderDailyStepsBar,
        'resting-hr-trendline':         renderRestingHRTrendline,
        'body-battery-gauge':           renderBodyBatteryGauge,
        'recent-activities-timeline':   renderRecentActivitiesTimeline,

        // Activities
        'weekly-distance-bar':          renderWeeklyDistanceBar,
        'activity-pace-altitude':       renderActivityPaceAltitudeAndReveal,
        'activity-hr-zones':            renderActivityHRZonesAndReveal,
        'activity-gps-map':             renderActivityGPSMapAndReveal,
        'activity-trim-controls':       renderActivityTrimControls,

        // Wellness
        'stress-body-battery-ts':       renderStressBodyBatteryTS,
        'hrv-daily-trend':              renderHrvDailyTrend,
        'hr-range-band':                renderHrRangeBand,
        'daily-steps-distance-combo':   renderDailyStepsDistanceCombo,
        'daily-intensity-minutes-bar':  renderDailyIntensityMinutesBar,
        'steps-hourly-heatmap':         renderStepsHourlyHeatmap,
        'respiration-spo2-ts':          renderRespirationSpo2TS,

        // Sleep
        'sleep-hypnogram':              renderSleepHypnogram,
        'sleep-stage-donut':            renderSleepStageDonut,
        'sleep-score-trend':            renderSleepScoreTrend,
        'sleep-duration-bar':           renderSleepDurationBar,
        'sleep-stage-stacked':          renderSleepStageStacked,
        'sleep-bed-wake-scatter':       renderSleepBedWakeScatter,
        'sleep-regularity-heatmap':     renderSleepRegularityHeatmap,
    };
})();

// test_chart_visibility.js — cover bootstrap.js's slot visibility rules.
//
// The viewer's JS normally only runs inside WKWebView on a Mac. This file
// gives the parts that are pure DOM logic a home on any machine with node:
// it stubs just enough of `document`/`window` for bootstrap.js to load, then
// drives `GarminDisconnect.render()` with payloads and asserts what happened
// to the slots.
//
// Scope is deliberately narrow — the `chart_hidden` path added for #261, and
// the `chart_empty` path next to it, because the two have to stay distinct:
// empty leaves a card with a message, hidden leaves nothing at all.
//
// Run:  node Tests/js/test_chart_visibility.js   (or `make test-js`)

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

// ---- Minimal DOM ---------------------------------------------------------
//
// Only the handful of APIs bootstrap.js touches on the paths under test.
// Anything it needs but we don't assert on is a no-op rather than a throw,
// so the file can load without a real browser.

class ClassList {
    constructor(el) { this.el = el; this.set = new Set(); }
    add(c) { this.set.add(c); }
    remove(c) { this.set.delete(c); }
    contains(c) { return this.set.has(c); }
    toggle(c, on) { if (on) this.add(c); else this.remove(c); }
    get value() { return Array.from(this.set).join(' '); }
}

class Element {
    constructor(tag) {
        this.tagName = String(tag).toUpperCase();
        this.classList = new ClassList(this);
        this.children = [];
        this.parentElement = null;
        this.textContent = '';
        this.id = '';
    }
    set className(v) {
        this.classList.set = new Set(String(v).split(/\s+/).filter(Boolean));
    }
    get className() { return this.classList.value; }
    set innerHTML(v) {
        if (v === '') { this.children.forEach(c => { c.parentElement = null; }); this.children = []; }
        this._html = v;
    }
    get innerHTML() { return this._html || ''; }
    appendChild(child) { child.parentElement = this; this.children.push(child); return child; }
    removeChild(child) {
        this.children = this.children.filter(c => c !== child);
        child.parentElement = null;
        return child;
    }
    querySelectorAll() { return []; }
    addEventListener() {}
    get hidden() { return this.classList.contains('hidden'); }
    /// Text a user would actually see in this slot, '' when it is hidden.
    get visibleText() {
        if (this.hidden) return '';
        return this.children.map(c => c.textContent).join('');
    }
}

function makeDocument() {
    const byId = new Map();
    const doc = {
        _byId: byId,
        getElementById: (id) => byId.get(id) || null,
        createElement: (tag) => new Element(tag),
        querySelectorAll: () => [],
        addEventListener: () => {},
    };
    doc._add = function (id, tag, className, parent) {
        const el = new Element(tag || 'div');
        el.id = id;
        if (className) el.className = className;
        if (parent) parent.appendChild(el);
        byId.set(id, el);
        return el;
    };
    return doc;
}

/// Build the slice of index.html this test cares about: two `.chart-grid`
/// rows, the GPS map alone in one and the trim control alone in the next,
/// exactly as the Activities tab lays them out.
function makePage() {
    const doc = makeDocument();
    const section = doc._add('activity-detail-section', 'div', '');
    const mapRow = doc._add('row-map', 'div', 'chart-grid one-col', section);
    const trimRow = doc._add('row-trim', 'div', 'chart-grid one-col', section);
    doc._add('chart-activity-gps-map', 'div', 'chart-slot gps-slot', mapRow);
    doc._add('chart-activity-trim-controls', 'div', 'trim-slot', trimRow);
    return doc;
}

function loadBootstrap(doc) {
    const src = fs.readFileSync(
        path.join(__dirname, '..', '..', 'Resources', 'web', 'bootstrap.js'), 'utf8'
    );
    const win = {
        document: doc,
        requestAnimationFrame: () => {},
        console: { warn() {}, error() {}, log() {} },
    };
    win.window = win;
    const ctx = vm.createContext(win);
    vm.runInContext(src, ctx, { filename: 'bootstrap.js' });
    return win;
}

// ---- Tiny test harness ---------------------------------------------------

let failures = 0;
function test(name, fn) {
    try {
        fn();
        console.log('  ok    ' + name);
    } catch (e) {
        failures++;
        console.log('  FAIL  ' + name + '\n        ' + e.message);
    }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }
function assertEqual(actual, expected, msg) {
    if (actual !== expected) {
        throw new Error((msg || '') + ' — expected ' + JSON.stringify(expected)
            + ', got ' + JSON.stringify(actual));
    }
}

function setup() {
    const doc = makePage();
    const win = loadBootstrap(doc);
    return {
        render: win.GarminDisconnect.render,
        trim: doc.getElementById('chart-activity-trim-controls'),
        trimRow: doc.getElementById('row-trim'),
        map: doc.getElementById('chart-activity-gps-map'),
        mapRow: doc.getElementById('row-map'),
    };
}

const HIDDEN = { chart: 'activity-trim-controls', chart_hidden: true };
const EMPTY = {
    chart: 'activity-trim-controls', chart_empty: true,
    message: 'No records for this activity',
};
// A real payload's shape doesn't matter here: charts.js isn't loaded, so the
// renderer lookup fails and render() bails after the un-hiding step. That is
// exactly the step under test.
const LIVE = {
    chart: 'activity-trim-controls', activity_id: 1,
    segments: [{ startS: 0, endS: 29 }], samples: [], trim: null,
};

console.log('===== chart visibility =====');

test('a hidden payload leaves nothing visible in the slot', () => {
    const p = setup();
    p.render(HIDDEN);
    assert(p.trim.hidden, 'the slot itself should be hidden');
    assertEqual(p.trim.visibleText, '', 'a hidden slot shows no text');
    assertEqual(p.trim.children.length, 0, 'a hidden slot holds no children');
});

test('hiding the only slot in a row hides the row, so no gap is left', () => {
    const p = setup();
    p.render(HIDDEN);
    assert(p.trimRow.hidden, 'the .chart-grid row should collapse too');
    assert(!p.mapRow.hidden, 'other rows are untouched');
});

test('an empty payload still shows its message', () => {
    const p = setup();
    p.render(EMPTY);
    assert(!p.trim.hidden, 'an empty slot stays visible');
    assert(!p.trimRow.hidden, 'and so does its row');
    assertEqual(p.trim.visibleText, 'No records for this activity');
});

test('a live payload brings a hidden slot and its row back', () => {
    const p = setup();
    p.render(HIDDEN);
    p.render(LIVE);
    assert(!p.trim.hidden, 'the slot should be visible again');
    assert(!p.trimRow.hidden, 'and its row with it');
});

test('empty after hidden is visible, and hidden after empty is not', () => {
    const p = setup();
    p.render(HIDDEN);
    p.render(EMPTY);
    assert(!p.trim.hidden, 'empty must un-hide');
    assertEqual(p.trim.visibleText, 'No records for this activity');
    p.render(HIDDEN);
    assert(p.trim.hidden, 'hidden must clear the message');
    assertEqual(p.trim.visibleText, '');
});

test('a row with a visible sibling stays visible', () => {
    const p = setup();
    // Put both slots in one row, as the two-col grids do elsewhere.
    p.trimRow.removeChild(p.trim);
    p.mapRow.appendChild(p.trim);
    p.render(HIDDEN);
    assert(p.trim.hidden, 'the slot is hidden');
    assert(!p.mapRow.hidden, 'but its row still holds the visible map');
});

console.log(failures === 0
    ? '\nall chart-visibility tests passed'
    : '\n' + failures + ' chart-visibility test(s) failed');
process.exit(failures === 0 ? 0 : 1);

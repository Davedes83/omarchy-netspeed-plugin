// Unit tests for Model.js — the pure formatting the bar repaints every sample.
//
// Run directly:  node tests/model_test.js
//
// Deliberately dependency-free (no node:test, no assert import) so the file
// runs on any Node without an install step.
//
// Model.js opens with `.pragma library`, which is a Quickshell directive and
// not valid JavaScript, so Node cannot require() it directly. The pragma is
// stripped and the remainder evaluated in this module's scope, which leaves
// every top-level function reachable by name — the same surface QML gets from
// `import "Model.js" as Model`.

var fs = require("fs");
var path = require("path");
var vm = require("vm");

var SRC = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma\s+library\s*$/m, "");
// `var` at top level of a vm script lands on the context object, so each
// function is pulled off it rather than off this module.
var ctx = {};
vm.createContext(ctx);
vm.runInContext(SRC, ctx, { filename: "Model.js" });

var failures = [];
var checks = 0;

function ok(cond, msg) {
  checks++;
  if (!cond) failures.push(msg);
}

function eq(actual, expected, msg) {
  checks++;
  if (actual !== expected) {
    failures.push(msg + "\n      expected: " + JSON.stringify(expected)
                         + "\n      actual:   " + JSON.stringify(actual));
  }
}

// ------------------------------------------------------- fixed-width cells
//
// The jitter this exists to kill: toFixed() guarantees a decimal POINT but not
// a WIDTH, so the label swung between 5 and 11 characters and dragged the rest
// of the bar with it on every sample.

eq(ctx.fmtSpeed(0.4).length, 12, "0.4 fills the full cell");
eq(ctx.fmtSpeed(9.9).length, 12, "9.9 fills the full cell");
eq(ctx.fmtSpeed(100).length, 12, "100 fills the full cell");
eq(ctx.fmtSpeed(1023.4).length, 12, "1023.4 fills the full cell");
eq(ctx.fmtSpeed(1048575).length, 12, "1048575 fills the full cell");
eq(ctx.fmtSpeed(0).length, 12, "zero fills the full cell");
// A 4-digit reading is padded on the LEFT so the number ends in the same column
// every time; otherwise the unit itself would shift.
eq(ctx.fmtSpeed(1023.4).substring(2, 6), "1023", "a 4-digit number is left-padded into the field");
eq(ctx.fmtSpeed(0).substring(0, 5), "     ", "a 1-digit number is padded out to the field");
eq(ctx.fmtSpeed(0).substring(5, 6), "0", "the number ends where the separating space begins");
// The field ends at column 6 either way, which is the whole point: a 1-digit
// and a 4-digit reading leave the unit in the same place.
eq(ctx.fmtSpeed(1023.4).substring(5, 6), "3", "a 4-digit number fills the field to its last column");
eq(ctx.fmtSpeed(0).substring(6, 7), " ", "a 1-digit number leaves the unit in the same column");
// The unit is right-padded, so "B/s" and "KiB/s" occupy the same columns and
// the unit text itself stays intact.
eq(ctx.fmtSpeed(0).substring(7), "B/s  ", "the short unit is padded to the unit width");
eq(ctx.fmtSpeed(2048).substring(7), "KiB/s", "the long unit is not padded beyond its own width");
eq(ctx.fmtSpeed(0).charAt(6), " ", "exactly one space separates number and unit");
// The number must never touch the unit, or the padding is not doing its job.
eq(ctx.fmtSpeed(0).substring(6).indexOf(" "), 0, "the separator is the first unit-field character");

// fmtBytes shares the unit width with fmtSpeed on purpose: the tooltip stacks
// a Total under the speeds, and two different widths would misalign them.
eq(ctx.fmtBytes(0).length, 12, "fmtBytes uses the same cell width as fmtSpeed");
eq(ctx.fmtBytes(1073741824).length, 12, "fmtBytes(1GiB) fills the full cell");
eq(ctx.fmtBytes(0).substring(7), "B    ", "fmtBytes pads its own unit to the same width");
eq(ctx.fmtBytes(0).charAt(6), " ", "fmtBytes separates number and unit the same way");

// --------------------------------------------------------- the bar's cell
//
// The bar label is two halves of "arrow, then a rate", and the arrow has to sit
// against its own figure. Neither end of the figure can be padded in front of
// it: a leading pad strands the arrow across blank space, worse the shorter the
// figure gets. So fmtSpeedCell pads the figure on its RIGHT, inside the cell.
//
// Why the right and not after the unit (both give the same cell width): padding
// the cell puts the slack at the end, so the gap between the two stats is that
// slack plus the separator between them -- five characters of blank on a short
// figure. Padding the figure keeps the slack inside the stat, so the gap
// between the two stats is the separator alone, on every sample.
//
// What must NOT change: the cell width. That is the whole jitter guarantee, and
// the bar label is what the padding exists for, so it has to hold here.

function barCell(arrow, bytesPerSec, compact) {
  return ctx.fmtSpeedCell(arrow, bytesPerSec, compact);
}

eq(ctx.barCellWidth(false), 13, "the full-form bar cell is arrow + figure + separator + unit");
eq(ctx.barCellWidth(true), 6, "the compact bar cell drops the separator and the /s");
eq(barCell("\u2193", 0).length, ctx.barCellWidth(false), "the full-form cell is its declared width");
eq(barCell("\u2193", 0, true).length, ctx.barCellWidth(true), "the compact cell is its declared width");

// The arrow is against the figure: the figure starts in the very next cell.
eq(barCell("\u2193", 0).charAt(1) === " ", false, "the cell puts nothing between arrow and figure");
eq(barCell("\u2193", 0).substring(1, 2), "0", "a 1-digit figure starts right after the arrow");
eq(barCell("\u2193", 1023.4).substring(1, 5), "1023", "a 4-digit figure starts right after the arrow");
eq(barCell("\u2193", 1048000).substring(1, 7), "1023.4", "a figure needing the whole field still starts at the front");

// The slack is INSIDE the cell, behind the figure -- so the unit is the last
// thing in the cell and nothing follows it.
eq(barCell("\u2193", 1023.4).trim().slice(-4), " B/s", "the unit ends the cell");
eq(barCell("\u2193", 0).substring(0, 5), "\u21930   ", "a short figure pads behind itself, not in front");
eq(barCell("\u2193", 0).trim().charAt(0) === " ", false, "the cell never opens with padding");
// Slack goes behind the figure: a 4-digit figure in a 6-wide field leaves two
// blank characters, plus the separator. The OLD layout put those in front of
// the figure instead, which is what put the arrow three characters from its
// number.
eq(barCell("\u2193", 1023.4).substring(5, 8), "   ",
   "a 4-digit figure leaves its slack behind it, not in front");

// The guarantee the whole thing exists for. A wide spread of figures, including
// every digit-count change the label can hit, must all produce the same cell
// width or the widget resizes and drags the rest of the bar with it.
var widths = [];
for (var v = 0; v <= 2000; v += 0.4) {
  widths.push(barCell("\u2193", v).length);
  widths.push(barCell("\u2193", v, true).length);
}
widths.push(barCell("\u2193", 1048576).length);
widths.push(barCell("\u2193", 1024 * 1024 * 1024).length);
var bad = widths.filter(function (w) { return w !== 13 && w !== 6; });
eq(bad.length, 0, "every bar cell is its declared width, for every figure (offenders: "
   + bad.slice(0, 5).join(",") + ")");

// Neither arrow moves, and the gap between the two stats is the separator and
// nothing else -- the complaint that started this: the slack used to land in
// that gap and swallow bar width.
function statLabel(down, up) {
  return barCell("\u2193", down) + " " + barCell("\u2191", up);
}
var labelLens = [];
var upCols = [];
var statGaps = [];
[0, 0.4, 9.9, 99.9, 100, 999.9, 1023.4, 1048000, 1048575, 1048576].forEach(function (v) {
  var l = statLabel(v, v);
  labelLens.push(l.length);
  upCols.push(l.indexOf("\u2191"));
  // Ink gap: where the upload cell's figure begins, minus where the download
  // cell's unit ends. Fixed by construction, but asserted because it is the
  // thing a regression would show up in.
  statGaps.push(l.indexOf("\u2191") - (l.indexOf("\u2193") + ctx.barCellWidth(false)));
});
eq(labelLens.every(function (l) { return l === labelLens[0]; }), true,
   "the assembled two-stat label is the same length for every pair of figures");
eq(upCols.every(function (c) { return c === upCols[0]; }), true,
   "the up-arrow sits in the same column whatever the figures are");
eq(statGaps.every(function (g) { return g === statGaps[0]; }), true,
   "the gap between the two stats never varies with the figures");
eq(statGaps[0], 1, "and it is just the single-space separator");

// ------------------------------------------------- the shipped default label
//
// BarWidget now defaults compactSpeed to on and joins the two cells with one
// space, because the full form occupies 28 characters -- at bar sizes that is a
// 200px slot made largely of padding. Anything that reintroduces the blank
// slack (a wider separator, a padded cell, or compact silently switching off)
// shows up here as a longer label.
function defaultLabel(down, up) {
  return barCell("\u2193", down, true) + " " + barCell("\u2191", up, true);
}
eq(defaultLabel(786432, 12288), "\u2193768K  \u219112K  ", "the shipped default label is compact");
eq(defaultLabel(0, 0).length, 13, "the default label is 13 characters wide");
var defaultWidths = [];
var defaultUpCols = [];
[0, 0.4, 9.9, 99.9, 100, 999.9, 1023.4, 1048000, 1048575, 1048576,
 1024 * 1024 * 1024].forEach(function (v) {
  var l = defaultLabel(v, v);
  defaultWidths.push(l.length);
  defaultUpCols.push(l.indexOf("\u2191"));
});
eq(defaultWidths.filter(function (w) { return w !== 13; }).length, 0,
   "the default label never changes width, whatever the figures");
eq(defaultUpCols.filter(function (c) { return c !== defaultUpCols[0]; }).length, 0,
   "the default label keeps the up-arrow in one column");
// The full form is still reachable by setting compactSpeed: false, and it is the
// same cell BarWidget used before -- this is the regression guard for that path.
eq(barCell("\u2193", 786432, false) + " " + barCell("\u2191", 12288, false),
   "\u2193768.0  KiB/s \u219112.0   KiB/s", "full units still available on request");
eq((barCell("\u2193", 0, false) + " " + barCell("\u2191", 0, false)).length, 27,
   "the full form is 27 characters when the separator is a single space");

// Compact form: same treatment, "768K" with nothing between arrow and figure.
eq(barCell("\u2193", 786432, true).substring(0, 5), "\u2193768K", "the compact figure starts right after the arrow");
eq(barCell("\u2193", 0, true).charAt(1) === " ", false, "nothing between arrow and compact figure");

// No reading yet: still a full-width cell, so the first sample does not resize
// the widget out from under the layout.
eq(barCell("\u2193", -1).length, ctx.barCellWidth(false), "a rate with no reading is still a full cell");
eq(barCell("\u2193", NaN).length, ctx.barCellWidth(false), "a non-finite rate is still a full cell");

// fmtSpeed itself is untouched by all of this -- the tooltip and the dropdown
// share it and want their unit column pinned.
eq(ctx.fmtSpeed(0).substring(0, 5), "     ", "the padded formatter is still left-padded");
eq(ctx.fmtSpeed(0, false).length, 12, "the padded cell is unchanged");
eq(ctx.fmtSpeed(0, true).length, 5, "the padded compact cell is unchanged");
eq(ctx.fmtSpeed(0).substring(7), "B/s  ", "the padded unit column is unchanged");
// The bare form is the same text with only the padding removed.
eq(ctx.fmtSpeedBare(0), "0 B/s", "the bare form is the padded form minus its padding");
eq(ctx.fmtSpeedBare(1023.4), "1023 B/s", "bare form, 4-digit figure");
eq(ctx.fmtSpeedBare(1048000), "1023.4 KiB/s", "bare form, full-width figure");
eq(ctx.fmtSpeedBare(0, true), "0B", "the bare compact form has no separator either");
eq(ctx.fmtSpeedBare(-1), "--", "a negative rate has no reading to show");
eq(ctx.fmtSpeedBare(NaN), "--", "a non-finite rate has no reading to show");

// ------------------------------------------------- unit-promotion rollover
//
// A real pre-existing bug: fmtSpeed(1023.9) rendered "1024 B/s", a value in
// bytes that is a round number in KiB. Promotion has to happen before ROUNDING
// can cross the boundary, and the two branches round at different points --
// Math.round at 1023.5, toFixed(1) at 1023.95 -- so the threshold is the
// earlier of the two.

eq(ctx.fmtSpeed(1023.4), "  1023 B/s  ", "just under the boundary stays in B/s");
eq(ctx.fmtSpeed(1023.5).indexOf("KiB/s") !== -1, true,
   "1023.5 promotes: Math.round(1023.5) would be 1024");
eq(ctx.fmtSpeed(1023.9), "   1.0 KiB/s",
   "1023.9 promotes rather than rounding up to an impossible 1024 B/s");
eq(ctx.fmtSpeed(1023.94).indexOf("KiB/s") !== -1, true, "1023.94 promotes");
eq(ctx.fmtSpeed(1023.95).indexOf("KiB/s") !== -1, true,
   "1023.95 promotes: toFixed(1) would round 1023.95 up to 1024.0");
eq(ctx.fmtSpeed(1024), "   1.0 KiB/s", "1024 is exactly 1.0 KiB/s");
eq(ctx.fmtSpeed(1048575), "   1.0 MiB/s",
   "1048575 was '1024.0KiB/s', an impossible value in that unit");
eq(ctx.fmtSpeed(1024 * 1024), "   1.0 MiB/s", "1 MiB/s");
eq(ctx.fmtSpeed(1024 * 1024 * 1024), "   1.0 GiB/s", "1 GiB/s");

// The invariant the promotion threshold exists to guarantee: no unit short of
// the top one ever renders a number at or above 1024.
var nonMaxViolations = [];
var probe = [0, 1, 512, 1023, 1023.4, 1023.49, 1023.5, 1023.9, 1023.94, 1023.95,
             1024, 1025, 2048, 9999, 65535, 1048575, 1048576, 1073741824,
             1099511627776, 1234567.89, 1023.9499, 999999.99];
for (var i = 0; i < probe.length; i++) {
  var rendered = ctx.fmtSpeed(probe[i]).trim();
  var m = /^([0-9.]+)/.exec(rendered);
  if (!m) { nonMaxViolations.push(probe[i] + " -> unparseable " + JSON.stringify(rendered)); continue; }
  var unit = rendered.replace(/^[0-9.]+\s*/, "");
  if (unit === "TiB/s") continue;          // the top unit has nothing above it
  if (parseFloat(m[1]) >= 1024) nonMaxViolations.push(probe[i] + " -> " + JSON.stringify(rendered));
}
eq(nonMaxViolations.join("; "), "", "no non-max unit renders a number >= 1024");

// Same reasoning, same threshold, in the totals formatter.
eq(ctx.fmtBytes(1023.9), "   1.0 KiB  ", "fmtBytes promotes at the same threshold");
eq(ctx.fmtBytes(1024), "   1.0 KiB  ", "fmtBytes(1024) is 1.0 KiB");
eq(ctx.fmtBytes(1048575), "   1.0 MiB  ", "fmtBytes promotes the same way fmtSpeed does");
eq(ctx.fmtBytes(1073741824), "   1.0 GiB  ", "fmtBytes(1GiB)");
var byteViolations = [];
for (var j = 0; j < probe.length; j++) {
  var br = ctx.fmtBytes(probe[j]).trim();
  var bm = /^([0-9.]+)/.exec(br);
  var bu = br.replace(/^[0-9.]+\s*/, "");
  if (bu === "TiB") continue;
  if (bm && parseFloat(bm[1]) >= 1024) byteViolations.push(probe[j] + " -> " + JSON.stringify(br));
}
eq(byteViolations.join("; "), "", "fmtBytes never renders a number >= 1024 in a non-max unit");

// ------------------------------------------------------------- compact form

// 768 KiB exactly, so the expected figure is checkable by hand.
eq(ctx.fmtSpeed(768 * 1024, true), " 768K", "compact drops /s and uses one letter");
eq(ctx.fmtSpeed(768 * 1024, true).length, 5, "compact is a fixed 5-character cell");
eq(ctx.fmtSpeed(768 * 1024, true).indexOf("KiB/s"), -1, "compact never spells out the unit");
eq(ctx.fmtSpeed(0, true).length, 5, "compact zero still fills its cell");
eq(ctx.fmtSpeed(1048576, true), "   1M", "compact promotes to a single-letter unit");
eq(ctx.fmtSpeed(1023.9, true), "   1K", "compact honours the same promotion");
// The widest compact number is 1023 (a 4-digit field); if promotion ever let a
// 5-digit number through, this would be the assertion that caught it.
eq(ctx.fmtSpeed(1023.4, true).length, 5, "a 4-digit compact number fills, not overflows, the field");
eq(ctx.fmtSpeed(1023.4, true), "1023B", "compact pads a 4-digit number to the field");
// No unit may render a number >= 1024 here either.
var compactViolations = [];
for (var c = 0; c < probe.length; c++) {
  var cr = ctx.fmtSpeed(probe[c], true).trim();
  var cm = /^([0-9]+)/.exec(cr);
  var cu = cr.replace(/^[0-9]+\s*/, "");
  if (cu === "T") continue;
  if (cm && parseFloat(cm[1]) >= 1024) compactViolations.push(probe[c] + " -> " + JSON.stringify(cr));
}
eq(compactViolations.join("; "), "", "compact never renders a number >= 1024 in a non-max unit");

// The formatter's second argument is optional, and omitting it keeps the full
// form. The widget decides which form to ask for (it now asks for compact by
// default); this is only the formatter's own default.
eq(ctx.fmtSpeed(768 * 1024), ctx.fmtSpeed(768 * 1024, false),
   "an omitted compact argument renders exactly like compact false");
eq(ctx.fmtSpeed(768 * 1024, false), " 768.0 KiB/s", "the full form is unchanged when off");
eq(ctx.fmtSpeed(768 * 1024, false).length, 12, "the full form keeps its 12-character cell");

// --------------------------------------------------- unchanged edge cases

// "--" is deliberately NOT padded to the cell width: it is the no-reading case,
// and a 12-character block of dashes and spaces in the tooltip would read as a
// broken column. Every value that EXISTS is padded.
eq(ctx.fmtSpeed(-1), "--", "a negative speed is still the bare placeholder");
eq(ctx.fmtSpeed(-0.5), "--", "a small negative speed is the placeholder");
eq(ctx.fmtSpeed(NaN), "--", "NaN is the placeholder");
eq(ctx.fmtSpeed(Infinity), "--", "Infinity is the placeholder");
eq(ctx.fmtSpeed(-Infinity), "--", "-Infinity is the placeholder");
eq(ctx.fmtSpeed(undefined), "--", "undefined is the placeholder");
eq(ctx.fmtSpeed("nonsense"), "--", "a non-numeric argument is the placeholder");
eq(ctx.fmtSpeed(0), "     0 B/s  ", "zero is a real reading, not a placeholder");
eq(ctx.fmtBytes(-1), "--", "a negative byte count is the placeholder");
eq(ctx.fmtBytes(NaN), "--", "NaN bytes is the placeholder");
eq(ctx.fmtBytes(0), "     0 B    ", "zero bytes is a real reading");

// ------------------------------------------------------ bounded ss streaming
//
// The socket table is machine-wide, so the number of rows `ss` can emit is not
// bounded by what this widget reports. `ss` offers no output-size option, so the
// plugin stops reading at SS_MAX_ROWS instead; these pin that the streaming path
// the panel now drives agrees with the batch parse and that the cap is a real
// bound.

// One socket = a record line carrying `users:(...)`, then a tab-indented info
// line carrying the byte counters.
function ssRow(pid, fd, local, sent, recv) {
  return "0      0      " + local + "   1.1.1.1:443   users:((\"app" + pid
    + "\",pid=" + pid + ",fd=" + fd + "))"
    + "\n\t bbr bytes_sent:" + sent + " bytes_received:" + recv;
}

// The batch entry point and the line-by-line path must not disagree: the panel
// uses the latter, the tests and any whole-text caller use the former.
var sample = ssRow(11, 3, "10.0.0.1:40001", 500, 900)
  + "\n" + ssRow(22, 7, "10.0.0.1:40002", 100, 200);
var batch = ctx.parseSS(sample, {});
var st = ctx.ssState({});
sample.split("\n").forEach(function(l) { ctx.ssLineStep(l, st) });
var streamed = ctx.finishSS(st);
eq(JSON.stringify(streamed.apps), JSON.stringify(batch.apps),
   "the streaming path attributes the same apps as the batch parse");
eq(JSON.stringify(streamed.next), JSON.stringify(batch.next),
   "the streaming path keeps the same baselines as the batch parse");
eq(streamed.rows, 2, "two sockets are attributed");
eq(streamed.apps.length, 2, "both pids appear");
eq(streamed.apps[0].deltaDown, 0, "the first poll has no baseline, so no delta");

// Deltas across polls: the same socket, more bytes, is the difference.
var st2 = ctx.ssState(streamed.next);
var pair2 = ssRow(11, 3, "10.0.0.1:40001", 700, 1400).split("\n");
ctx.ssLineStep(pair2[0], st2);
ctx.ssLineStep(pair2[1], st2);
var second = ctx.finishSS(st2);
eq(second.apps[0].deltaUp, 200, "deltaUp is the byte difference between polls");
eq(second.apps[0].deltaDown, 500, "deltaDown is the byte difference between polls");

// The info line is matched to the row BEFORE it, so a row is one attribution.
var st3 = ctx.ssState({});
var pair3 = ssRow(1, 1, "10.0.0.1:1", 10, 20).split("\n");
ctx.ssLineStep(pair3[0], st3);
ctx.ssLineStep(pair3[1], st3);
eq(ctx.finishSS(st3).rows, 1, "a row plus its info line is one attribution");

// A bare info line with no preceding row must not invent an attribution.
var st4 = ctx.ssState({});
ctx.ssLineStep("\t bytes_sent:99 bytes_received:99", st4);
eq(ctx.finishSS(st4).rows, 0, "an orphan info line attributes nothing");

// The row cap is the whole point: a stream far larger than the cap is stopped
// at the cap rather than fully consumed.
var cap = ctx.SS_MAX_ROWS;
eq(typeof cap, "number", "SS_MAX_ROWS is exposed for the panel and the notice");
ok(cap > 0, "the row cap is a positive bound");

var big = [];
for (var b = 0; b < cap * 3; b++) big.push(ssRow(1000 + b, 3, "10.0.0.1:" + (50000 + b), b, b));
var linesBig = big.join("\n").split("\n");
var stBig = ctx.ssState({});
var consumed = 0;
for (var q = 0; q < linesBig.length; q++) {
  ctx.ssLineStep(linesBig[q], stBig);
  consumed++;
  if (stBig.rows >= cap) break;
}
eq(stBig.rows, cap, "streaming stops at exactly SS_MAX_ROWS sockets");
ok(consumed < linesBig.length,
   "stopping at the cap leaves most of the stream unread (read " + consumed
   + " of " + linesBig.length + ")");

// -------------------------------------------------------------------- done

if (failures.length > 0) {
  console.error("\nModel.js: " + failures.length + " of " + checks + " assertions FAILED\n");
  for (var k = 0; k < failures.length; k++) {
    console.error("  - " + failures[k]);
  }
  console.error("");
  process.exit(1);
}
console.log("Model.js: " + checks + " assertions passed");
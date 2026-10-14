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

// Default OFF: the second argument is optional, and every existing caller that
// passes only the value keeps the full form. This is what makes the setting
// opt-in rather than a behaviour change for existing users.
eq(ctx.fmtSpeed(768 * 1024), ctx.fmtSpeed(768 * 1024, false),
   "compactSpeed absent renders exactly like compactSpeed false");
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
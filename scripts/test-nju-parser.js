#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../Resources/Timetable/njubksjw2.js"), "utf8");

// A minimal tree DOM models ownership, nested tables, computed ancestor CSS,
// and rendered rectangles. No browser, network, dependencies, or credentials.
class Element {
  constructor(tag, children = [], options = {}) {
    this.nodeType = 1; this.tagName = tag.toUpperCase(); this.parentElement = null;
    this.childNodes = []; this.hidden = options.hidden || false;
    this.attributes = options.attributes || {}; this.style = options.style || {};
    this.rects = options.rects || [{ width: 800, height: 30 }];
    for (const child of children) this.append(child);
  }
  append(child) {
    if (typeof child === "string") child = { nodeType: 3, nodeValue: child };
    child.parentElement = this; this.childNodes.push(child); return child;
  }
  get textContent() { return this.childNodes.map(child => child.nodeType === 3 ? child.nodeValue : child.textContent).join(""); }
  getAttribute(name) { return this.attributes[name] || null; }
  getClientRects() { return this.rects; }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) {
      if (node.tagName === selector.toUpperCase()) return node;
    }
    return null;
  }
  querySelectorAll(selector) {
    const tags = selector.split(",").map(tag => tag.toUpperCase());
    const found = [];
    function walk(node) {
      for (const child of node.childNodes || []) {
        if (tags.includes(child.tagName)) found.push(child);
        walk(child);
      }
    }
    walk(this); return found;
  }
  get rows() { return this.querySelectorAll("tr").filter(row => row.closest("table") === this); }
  get cells() { return this.childNodes.filter(child => ["TD", "TH"].includes(child.tagName)); }
}
function row(values) { return new Element("tr", values.map(value => new Element("td", Array.isArray(value) ? value : [value]))); }
function course(time, { name = "高等数学", code = "001", teacher = "示例教师" } = {}) {
  return row(["1", code, name, "4", teacher, "必修", time, "", "备注", "", "期末待定"]);
}
function table(rows, hidden = false) { return new Element("table", [new Element("tbody", rows)], { hidden }); }
const header = () => row(["序号", "课程号", "课程名称", "学分", "教师", "性质", "时间地点", "", "备注", "", "考试"]);
function parse(rows, options = {}) {
  const actualTable = table(rows);
  const unrelatedTable = table([row(["菜单", "并非课程"])]);
  const targetTrees = options.tables || [unrelatedTable, actualTable];
  const term = new Element("span", [options.term === undefined ? "2026-2027学年 第1学期" : options.term]);
  const scope = new Element("div", [term, ...targetTrees]);
  const document = {
    querySelector: selector => selector === "#dqxnxqkclb" ? (options.missingTerm ? null : term) : null,
    querySelectorAll: selector => scope.querySelectorAll(selector)
  };
  const location = { protocol: "https:", hostname: "ehallapp.nju.edu.cn", pathname: "/jwapp/sys/wdkb/*default/index.do", ...options.location };
  const globals = { document, location, getComputedStyle: node => ({ display: "table", visibility: "visible", opacity: "1", contentVisibility: "visible", ...node.style }) };
  const wrapped = `(function() { const teachshelfSelectedTableID = ${JSON.stringify(options.selectedID ?? null)}; const result = ${source}\n; return result; })()`;
  const encoded = vm.runInNewContext(options.omitSelectedID ? source : wrapped, globals, { timeout: 1000 });
  return JSON.parse(decodeURIComponent(encoded));
}
const cases = [
  ["finds the actual course table, skips header, parses multiple meetings", () => {
    const result = parse([header(), course("周三 2-4节 1-3周,10-13周 仙Ⅱ-304，周五 5-6节 2-8周 仙I-101")]);
    assert.equal(result.name, "2026-2027学年 第1学期");
    assert.equal(result.courses.length, 2);
    assert.deepEqual(result.courses[0].weeks, [1, 2, 3, 10, 11, 12, 13]);
    assert.equal(result.courses[0].time_count, 2);
    assert.equal(result.courses[0].classroom, "仙Ⅱ-304");
    assert.equal(result.courses[1].week_time, 5);
    assert.deepEqual(result.warnings, []);
    const oldNative = parse([header(), course("周一 1节 1周 教室")], { omitSelectedID: true });
    assert.equal(oldNative.courses.length, 1);
  }],
  ["handles odd/even weeks, fullwidth parentheses, and single sections", () => {
    const result = parse([course("星期二 5节 2-10周（双）；周日 3至4节 1-8周(单周) 自由教室")]);
    assert.equal(result.courses.length, 2);
    assert.deepEqual(result.courses[0].weeks, [2, 4, 6, 8, 10]);
    assert.equal(result.courses[0].start_time, 5);
    assert.equal(result.courses[0].time_count, 0);
    assert.equal(result.courses[0].classroom, null);
    assert.deepEqual(result.courses[1].weeks, [1, 3, 5, 7]);
    assert.equal(result.courses[1].week_time, 7);
  }],
  ["handles Chinese week commas and duplicate weeks", () => {
    const result = parse([course("周一 1-2节 1-3周，3周、5周 教室 101")]);
    assert.deepEqual(result.courses[0].weeks, [1, 2, 3, 5]);
    assert.equal(result.courses[0].classroom, "教室 101");
  }],
  ["keeps line wrapping within a meeting and separates new weekday lines", () => {
    const result = parse([course("周一\n１-２节\n1-3周 教室甲\n周三 4节 1周 教室乙")]);
    assert.equal(result.courses.length, 2);
    assert.equal(result.courses[0].time_count, 1);
    assert.equal(result.courses[1].classroom, "教室乙");
    assert.deepEqual(result.warnings, []);
  }],
  ["keeps explicit and unspecified free-time courses", () => {
    const result = parse([course("自由时间 1-5周(单)；自由时间")]);
    assert.equal(result.courses.length, 2);
    assert.deepEqual(result.courses[0].weeks, [1, 3, 5]);
    assert.deepEqual(result.courses[1].weeks, []);
    assert.equal(result.courses[1].week_time, 0);
    assert.equal(result.courses[1].start_time, 0);
    assert.match(result.warnings[0], /未注明周次/);
  }],
  ["does not silently lose malformed rows or unknown weekdays", () => {
    const result = parse([header(), row(["bad", "short"]), course("周八 1-2节 1-3周 教室；周一 3节 1-3周 教室")]);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].week_time, 1);
    assert.equal(result.warnings.length, 2);
    assert.match(result.warnings[0], /列数不足/);
    assert.match(result.warnings[1], /星期/);
  }],
  ["reports invalid week and section ranges without inventing meetings", () => {
    const result = parse([course("周一 4-2节 1-3周 101；周三 2节 0-4周 102；周五 6节 2周 103")]);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].classroom, "103");
    assert.equal(result.warnings.length, 2);
    assert.match(result.warnings[0], /节次/);
    assert.match(result.warnings[1], /周次/);
  }],
  ["refuses missing/empty/unrelated pages and offers choices for distinct lists", () => {
    assert.throws(() => parse([course("周一 1节 1周 教室")], { missingTerm: true }), /当前学期/);
    assert.throws(() => parse([header()]), /没有找到/);
    assert.throws(() => parse([course("garbage")]), /没有找到/);
    const choice = parse([], { tables: [table([header(), course("周一 1节 1周 A")]), table([header(), course("周二 2节 1周 B")])] });
    assert.equal(choice.tables.length, 2);
    assert.deepEqual(choice.courses, []);
    assert.throws(() => parse([], { location: { hostname: "ehallapp.nju.edu.cn.evil.invalid" } }), /本科教务/);
    assert.throws(() => parse([], { location: { protocol: "http:" } }), /本科教务/);
    assert.throws(() => parse([], { location: { pathname: "/gsapp/sys/wdkbapp/" } }), /本科教务/);
  }],
  ["ignores nested layout and frozen operation tables instead of double-counting rows", () => {
    const full = table([header(), course("周一 1-2节 1-3周 教室甲")]);
    const layoutRow = row(["", "", "外层布局", "", "", "", [full], "", "", "", ""]);
    const outer = table([layoutRow]);
    const frozen = table([row(["操作"]), row(["查看"]) ,row(["查看"])]);
    const result = parse([], { tables: [frozen, outer] });
    assert.equal(result.tables, undefined);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].name, "高等数学");
    assert.deepEqual(result.warnings, []);
  }],
  ["does not include a nested table's cell text in course fields", () => {
    const record = course("周三 2节 3周 教室乙");
    record.cells[2].append(table([row(["操作菜单"])]));
    const result = parse([header(), record]);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].name, "高等数学");
  }],
  ["excludes CSS-hidden ancestors, aria-hidden ancestors, hidden tables, and nonrendered clones", () => {
    const hiddenAncestorStyles = [
      { display: "none" }, { visibility: "hidden" }, { visibility: "collapse" },
      { opacity: "0" }, { contentVisibility: "hidden" }
    ];
    const hiddenTrees = hiddenAncestorStyles.map(style => new Element("div", [table([header(), course("周五 4节 4周 隐藏教室")])], { style }));
    hiddenTrees.push(new Element("div", [table([course("周五 4节 4周 aria教室")])], { attributes: { "aria-hidden": "true" } }));
    hiddenTrees.push(table([course("周五 4节 4周 hidden教室")], true));
    const noRects = table([course("周五 4节 4周 导出副本")]); noRects.rects = [];
    const zeroRect = table([course("周五 4节 4周 零尺寸副本")]); zeroRect.rects = [{ width: 0, height: 0 }];
    const visibleTable = table([header(), course("周一 1节 1周 正常教室")]);
    const result = parse([], { tables: [...hiddenTrees, noRects, zeroRect, visibleTable] });
    assert.equal(result.tables, undefined);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].classroom, "正常教室");
  }],
  ["collapses only exact course-row clones after whitespace normalization", () => {
    const first = table([header(), course("周一 1节 1周 教室 A")]);
    const clone = table([header(), course("  周一  1节   1周  教室 A  ", { name: "  高等数学  " })]);
    const result = parse([], { tables: [first, clone] });
    assert.equal(result.tables, undefined);
    assert.equal(result.courses.length, 1);
    const repeatedRows = parse([header(), course("周一 1节 1周 教室 A"), course("周一 1节 1周 教室 A")]);
    assert.equal(repeatedRows.courses.length, 2);
  }],
  ["offers stable explicit choices for distinct visible lists and selects by content identity", () => {
    const firstRows = () => [header(), course("周一 1节 1周 教室 A", { name: "示例甲", code: "A" })];
    const secondRows = () => [header(), course("周二 2节 2周 教室 B", { name: "示例乙", code: "B" })];
    const choices = parse([], { tables: [table(firstRows()), table(secondRows())] });
    assert.equal(choices.tables.length, 2);
    assert.equal(choices.tables[0].rowCount, 1);
    assert.deepEqual(choices.tables[0].preview, ["示例甲"]);
    assert.notEqual(choices.tables[0].id, choices.tables[1].id);
    assert.doesNotMatch(choices.tables[0].id, /示例甲|教室/);
    const chosen = parse([], { tables: [table(secondRows()), table(firstRows())], selectedID: choices.tables[0].id });
    assert.equal(chosen.courses.length, 1);
    assert.equal(chosen.courses[0].name, "示例甲");
    assert.equal(chosen.courses[0].classroom, "教室 A");
    assert.throws(() => parse([], { tables: [table(secondRows())], selectedID: choices.tables[0].id }), /已变化.*已失效/);
  }],
  ["does not merge different rooms, different weeks, or strict subsets by course name", () => {
    const a = () => course("周一 1节 1周 教室 A");
    const b = () => course("周一 1节 1周 教室 B");
    const c = () => course("周一 1节 2周 教室 A");
    const result = parse([], { tables: [table([header(), a()]), table([header(), b()]), table([header(), c()]), table([header(), a(), b()])] });
    assert.equal(result.tables.length, 4);
    assert.deepEqual(result.tables.map(choice => choice.rowCount), [1, 1, 1, 2]);
  }],
  ["requires an actual period or free-time marker in the time column", () => {
    const grades = table([header(), course("90分 优秀", { name: "成绩列表", code: "GRADE" })]);
    const real = table([header(), course("自由时间", { name: "自主研习", code: "FREE" })]);
    const result = parse([], { tables: [grades, real] });
    assert.equal(result.tables, undefined);
    assert.equal(result.courses.length, 1);
    assert.equal(result.courses[0].name, "自主研习");
  }]
];
let failed = 0;
for (const [name, run] of cases) {
  try { run(); process.stdout.write(`✓ ${name}\n`); }
  catch (error) { failed++; process.stderr.write(`✗ ${name}\n${error.stack}\n`); }
}
if (failed) process.exitCode = 1;
else process.stdout.write(`${cases.length} undergraduate parser tests passed.\n`);

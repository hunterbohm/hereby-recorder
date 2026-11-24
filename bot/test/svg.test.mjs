// A custom picture's SVG made safe (public/board/svg.mjs): the board room keeps only what cleanSvg returns, and the
// page shows that as an image. Each attack here must come out harmless. Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { cleanSvg, drawsSomething } from '../public/board/svg.mjs';

const BOX = '<rect x="10" y="10" width="100" height="40" rx="14" fill="#ffffff"/>';
const wrap = (inner, open = '<svg viewBox="0 0 1000 520">') => `${open}${inner}</svg>`;
// Nothing that can run, load or link survives anywhere in the output.
const DANGER = /script|on[a-z]+\s*=|href|foreignObject|<style|<image|<use|<a[\s>]|<iframe|<animate|<set|javascript:|data:|url\((?!#)|@import|<!|<\?|&(?!amp;|lt;|gt;|quot;)/i;

test('a plain picture comes through, rebuilt: shapes, words, the arrowhead marker and its reference', () => {
  const svg = wrap(`<defs><marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">`
    + `<path d="M0 0L10 5L0 10z" fill="#8a94a0"/></marker></defs>${BOX}`
    + `<line x1="110" y1="30" x2="300" y2="30" stroke="#8a94a0" stroke-width="3" marker-end="url(#a)"/>`
    + `<text x="60" y="30" text-anchor="middle" dominant-baseline="middle" font-size="24" font-weight="700">API &amp; app<tspan x="60" dy="28">v2</tspan></text>`);
  const got = cleanSvg(svg);
  assert.ok(got.startsWith('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 520">'));
  for (const part of ['<marker id="a"', 'marker-end="url(#a)"', '<path d="M0 0L10 5L0 10z" fill="#8a94a0"/>', 'API &amp; app', '<tspan x="60" dy="28">v2</tspan>']) {
    assert.ok(got.includes(part), part);
  }
  assert.ok(drawsSomething(got));
  assert.equal(drawsSomething(cleanSvg('<svg viewBox="0 0 10 10"><g></g></svg>')), false);
});

test('scripts, handlers, links, styles, foreign content and animation are all taken out', () => {
  const attacks = [
    '<script>alert(1)</script>', '<script href="https://x.test/a.js"/>', `<rect onload="alert(1)" onclick='x()' ONMOUSEOVER=y width="5" height="5"/>`,
    '<foreignObject width="100" height="100"><iframe src="https://x.test"></iframe><div onclick="x()">hi</div></foreignObject>',
    '<a href="javascript:alert(1)"><text x="1" y="1">click</text></a>', '<a xlink:href="https://x.test"><rect width="1" height="1"/></a>',
    '<image href="https://x.test/p.png" width="10" height="10"/>', '<use href="#a"/>', '<use xlink:href="https://x.test/s.svg#x"/>',
    '<style>@import url(https://x.test/a.css); rect { fill: url(https://x.test/x) }</style>', '<rect style="fill:url(https://x.test)" width="1" height="1"/>',
    '<animate attributeName="href" to="javascript:alert(1)"/>', '<set attributeName="onload" to="alert(1)"/>',
    '<svg onload="alert(1)"><script>x</script></svg>', '<rect fill="url(https://x.test/x)" width="1" height="1"/>',
    '<rect fill="url(data:image/svg+xml,AAA)" width="1" height="1"/>', '<rect filter="url(#f)" width="1" height="1"/><filter id="f"/>',
    '<rect width="1" height="1" transform="translate(1) expression(alert(1))"/>', '<path d="M0 0 L10 10 javascript:alert(1)"/>',
    '<text x="1" y="1"><![CDATA[<script>alert(1)</script>]]></text>', '<!-- <script>alert(1)</script> --><rect width="1" height="1"/>',
    '<rect id="x&quot; onload=&quot;alert(1)" width="1" height="1"/>', '<text x="1" y="1">&lt;script&gt;alert(1)&lt;/script&gt;</text>',
    '<SCRIPT>alert(1)</SCRIPT>', '<sCrIpT>alert(1)</sCrIpT>', '<rect width=1 height=1 onload=alert(1)/>', '<html:script>alert(1)</html:script>',
    '<rect width="1" height="1" __proto__="x" constructor="y"/>', '<marker id="m"><script>alert(1)</script></marker>',
    '<text x="1" y="1" fill="#000">ok</text><iframe srcdoc="<script>alert(1)</script>"></iframe>',
  ];
  for (const attack of attacks) {
    const got = cleanSvg(wrap(attack));
    if (got === null) continue;
    // Markup written as words (&lt;script&gt;) is plain text in a picture, and harmless.
    assert.doesNotMatch(got.replace(/&lt;\/?script&gt;/g, ''), DANGER, attack);
  }
  // Words that look like markup stay words.
  assert.ok(cleanSvg(wrap('<text x="1" y="1">&lt;script&gt;alert(1)&lt;/script&gt;</text>')).includes('&lt;script&gt;'));
});

test('a doctype, an entity or a processing instruction is never read: before the picture it is skipped, inside it refused', () => {
  assert.equal(cleanSvg('<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x "&#x3C;script&#x3E;">]><svg>&x;<text x="1" y="1">&x;</text></svg>'),
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 520"><text x="1" y="1">&amp;x;</text></svg>');
  assert.equal(cleanSvg(wrap('<!ENTITY x "y">')), null);
  assert.equal(cleanSvg(wrap('<?php echo 1 ?>')), null);
});

test('a picture is kept within its size: too big, too many shapes or too deep is refused or cut, never passed through', () => {
  assert.equal(cleanSvg(wrap(BOX.repeat(5000))), null, 'past 64 KB in');
  assert.equal(cleanSvg(wrap('<circle cx="1" cy="1" r="1"/>'.repeat(700))), null, 'past 600 shapes');
  const deep = cleanSvg(wrap(`${'<g>'.repeat(40)}${BOX}${'</g>'.repeat(40)}`));
  assert.ok(!deep || (deep.match(/<g>/g) || []).length < 16, 'no deeper than 16');
  const words = cleanSvg(wrap(`<text x="1" y="1">${'a'.repeat(2000)}</text>`));
  assert.ok(words.length < 600, 'a text node is cut short');
  assert.equal(cleanSvg('hello'), null);
  assert.equal(cleanSvg(''), null);
  assert.equal(cleanSvg(null), null);
});

test('a picture still being written is closed where it stops, and its size comes from what it says', () => {
  const part = cleanSvg('Here you go: <svg width="800" height="400"><g><rect x="1" y="1" width="10" height="10"/><text x="5" y="5">Pay');
  assert.equal(part, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 400"><g><rect x="1" y="1" width="10" height="10"/><text x="5" y="5">Pay</text></g></svg>');
  assert.equal(cleanSvg('<svg viewBox="0 0 10 10"><rect x="1" y="1" wid'), '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>');
  assert.equal(cleanSvg('<svg viewBox="0 0 1e9 10"/>'), '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 520"></svg>');
  // A second picture inside the first is dropped whole.
  assert.doesNotMatch(cleanSvg(wrap('<svg><rect width="1" height="1"/></svg>' + BOX)), /<svg[^>]*>.*<svg/);
});

test('no value makes the sanitizer slow: a long run that fails, fails at once', () => {
  const slow = [
    `<rect x="${'1'.repeat(190)}!" width="5" height="5"/>`, `<polyline points="${'1'.repeat(3900)}!"/>`,
    `<rect stroke-dasharray="${'1 '.repeat(95)}x" width="5" height="5"/>`, `<rect width="${'9'.repeat(22)}!" height="5"/>`,
    `<g transform="${('translate(1)' + ' '.repeat(6)).repeat(16)}x"><rect width="5" height="5"/></g>`,
    '<q>'.repeat(6600) + '</g>'.repeat(5000),
  ];
  for (const inner of slow) {
    const started = performance.now();
    cleanSvg(wrap(inner));
    assert.ok(performance.now() - started < 200, `${inner.slice(0, 40)}… took ${Math.round(performance.now() - started)} ms`);
  }
  // Plain lists of numbers and transforms still pass, with or without commas, and a minus sign may part two numbers.
  const kept = cleanSvg(wrap('<polyline points="10,20 30 40,-5-6 .5.5"/><g transform="translate(10, 20) rotate(45 5 5),scale(2)"><rect width="5" height="5"/></g>'));
  assert.ok(kept.includes('points="10,20 30 40,-5-6 .5.5"'), kept);
  assert.ok(kept.includes('transform="translate(10, 20) rotate(45 5 5),scale(2)"'), kept);
  assert.equal(cleanSvg(wrap('<g transform="translate(1) evil(2)"><rect width="5" height="5"/></g>')).includes('transform'), false);
});

test('markers stay one level deep and only at the ends of a line, so no picture takes minutes to paint', () => {
  const corners = ' 1 1 0 0'.repeat(150);
  const nested = '<defs>' + ['a', 'b', 'c'].map((id, i, all) => `<marker id="${id}" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9">`
    + `<path d="M0 0${corners}" marker-mid="url(#${all[i + 1] || 'a'})" marker-end="url(#${all[i + 1] || 'a'})"/></marker>`).join('')
    + `</defs><path d="M0 0${corners}" marker-mid="url(#a)" marker-end="url(#a)"/>`;
  const got = cleanSvg(wrap(nested));
  assert.equal(got.includes('marker-mid'), false);
  // Only the top-level path keeps its end marker; the markers' own paths keep none.
  assert.equal(got.match(/marker-end/g).length, 1);
  assert.ok(got.includes('<marker id="a"'));
});

test('nothing around a marker can hand its shapes a marker: markers live only in a plain <defs> under the picture', () => {
  const mark = (id, next) => `<marker id="${id}" markerWidth="9" markerHeight="9"><path d="M0 0L9 9"/></marker>`
    .replace('<marker', next ? `<g marker-end="url(#${next})"><marker` : '<marker') + (next ? '</g>' : '');
  // A group with a marker setting around a marker: the marker goes, with what it holds.
  const wrapped = cleanSvg(wrap(`<defs>${mark('a', 'b')}${mark('b', 'a')}</defs><path d="M0 0L9 9" marker-end="url(#a)"/>`));
  assert.equal(wrapped.includes('<marker'), false, wrapped);
  // A marker setting on the <defs> itself is dropped, and its markers stay.
  const onDefs = cleanSvg(wrap('<defs marker-end="url(#a)"><marker id="a"><path d="M0 0L9 9"/></marker></defs>'));
  assert.ok(onDefs.includes('<defs><marker id="a">'), onDefs);
  // A <defs> inside a group is no home for a marker either.
  const deep = cleanSvg(wrap('<g marker-start="url(#a)"><defs><marker id="a"><path d="M0 0L9 9"/></marker></defs></g>'));
  assert.equal(deep.includes('<marker'), false, deep);
  // The arrowhead every picture uses is kept as it is.
  const arrow = '<defs><marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" '
    + 'orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#8a94a0"/></marker></defs>';
  assert.ok(cleanSvg(wrap(arrow)).includes(arrow));
});

test('what would stop the image from showing at all is left out: a second copy of an attribute, U+FFFE and U+FFFF', () => {
  assert.ok(cleanSvg(wrap('<rect x="1" x="2" width="100" height="100"/>')).includes('<rect x="1" width="100" height="100"/>'));
  const words = cleanSvg(wrap('<text x="1" y="1">a&#xFFFE;b￿c&#65535;d</text>'));
  assert.ok(words.includes('>abcd</text>'), words);
});

test('a picture with more than 64 elements open at once is refused', () => {
  assert.equal(cleanSvg(wrap('<q>'.repeat(70))), null);
  assert.ok(cleanSvg(wrap('<q>'.repeat(10) + BOX)));
});

test('a label may say "<", a cut emoji becomes one mark, and a dash pattern is never finer than 4 units', () => {
  const words = cleanSvg(wrap('<text x="1" y="1">p95 < 200 ms</text>'));
  assert.ok(words.includes('>p95 &lt; 200 ms</text>'), words);
  // The label is cut at 300 places, through the middle of the emoji: what is left is still well formed.
  const cut = cleanSvg(wrap(`<text x="1" y="1">${'a'.repeat(299)}😀</text>`));
  assert.ok(cut.includes(`${'a'.repeat(299)}�</text>`));
  assert.equal(cut, cut.toWellFormed());
  assert.ok(cleanSvg(wrap('<path d="M0 0L9 9" stroke-dasharray="8 6"/>')).includes('stroke-dasharray="8 6"'));
  for (const fine of ['0.5', '1 1', '1,0.5,1']) {
    assert.equal(cleanSvg(wrap(`<path d="M0 0L9 9" stroke-dasharray="${fine}"/>`)).includes('stroke-dasharray'), false, fine);
  }
});

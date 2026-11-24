# The board's blocks

The live whiteboard is a title and a few blocks. Each block is one kind of picture, and every later change adds to a
block or puts a new one beside it, so the picture grows rather than being redrawn. This file is the contract for the
block set in `public/board/`: what a block is, which file does what, and how to add a kind. The set has no framework
and no build step; it is plain ES modules, DOM and SVG, so it can be lifted out whole.

## A board

```js
{ v: 2, title: 'Q1 launch', recap: true /* only on the recap board */, blocks: [
  { id: 'signups', type: 'chart', title: 'Signups by month', unit: 'signups', items: [
    { id: 'oct', text: 'October', value: 120 }, { id: 'nov', text: 'November', value: 180 }] }] }
```

Ids are unique across the whole board (blocks, items and table or chart columns), short, and only letters, digits, `_`
and `-`. The limits are in `model.mjs` (`LIMITS`, `CHARS`): 6 blocks, 12 items a block, 48 in all, 5 columns, 12 links,
2 custom pictures, 12 sparkline points, a picture's SVG at most 20,000 characters.
A whole board (one from before blocks, or one Hermes sends whole) keeps up to 8 blocks, the most sections an old board
held, so none is lost; edits still add blocks only up to 6. A room saved before blocks has its boards made lists as it
opens (`src/room.js`).

| type | what it shows | block settings | item fields |
|---|---|---|---|
| `list` | cards of one kind | `kind`: goals, risks, actions, decisions, pros, cons, notes | `owner`, `due`, `level` (high, medium, low) |
| `flow` | steps in order joined by arrows | `links: [{from, to, label?}]` | `shape`: step, decision, start, end |
| `timeline` | milestones in time order | | `when`, `status`: done, now, next, late |
| `chart` | numbers by category | `unit`, `style` (below), `columns` (the series) | `value`, or `cells` by column |
| `table` | options compared on criteria | `columns` (the options), `pick`, `scale` (5 or 10) | `cells` by column: a score or words |
| `matrix` | a 2x2 | `x` and `y` `{low, high}`, `quadrants` `{tl, tr, bl, br}` | `quadrant` |
| `mindmap` | a topic and its branches | (the title is the center) | `parent` |
| `stats` | a few key numbers, big | | `value`, `note`, `trend`: up, down, flat; `target` (a meter), `points` (a sparkline) |
| `funnel` | stages people or deals drop out of | `unit` | `value` |
| `roadmap` | work over date ranges, by team | | `lane`, `start`, `end` (as said: "Jan", "Q3", "2027-02"), `status` |
| `tree` | a hierarchy, top down: an org chart | | `parent`, `note` (a role) |
| `swimlane` | steps in order, by who does each | `links` | `lane`, `shape` |
| `sketch` | a custom picture Hermes draws as SVG | `brief` (what it shows); `svg`, `drawing`, `failed` are set by the room | |

A chart's `style` is how its numbers are drawn: `bar` (compare categories), `line` (over time), `stacked` (two or more
series that add up), `donut` or `pie` (parts of one whole; more than six fold into "Other"), `heatmap` (rows by three
or more columns, shaded by size). A `unit` of `$`, `€`, `£` or `%` goes on every number; `$M`, `$k` or `$B` also says the
size the numbers leave out ("4.6" shows as "$4.6M"); any other unit is said once beside the title.

Drawing a block another way is one block edit that keeps its items: a chart's `style`, or a `type` that shares the
items' fields (a timeline as a roadmap, a flow as a swimlane, a chart as a funnel). `shapeOf()` in `blocks.mjs` starts
the drawing over when the shape changes. A chart that gets its first series moves each item's `value` into that series'
cell, so "add the Q4 forecast" as a second series never loses the numbers already there.

A link that joins a step to the very next one is drawn on that arrow ("No") rather than as a second arrow.

## The files

| file | does | needs a page |
|---|---|---|
| `model.mjs` | the types, fields, limits, `emptyBoard`, `upgrade` (a board from before blocks, as lists), `index`, `numberOf` | no |
| `kinds.mjs` | a list's kinds, and the kind a title implies | no |
| `sizes.mjs` | `need(block, density)`: the least, best and most width, and the height at a width | no |
| `arrange.mjs` | `arrange(blocks, {width, height, previous, density})`: rows of at most three, each spanning the width | no |
| `view.mjs` | `plan()`: the density that fits (1, 0.9, 0.8, 0.72); `render()`: keyed blocks, what changed marked | `render` only |
| `blocks.mjs` | `draw(node, block, {w, h, changed, link, instant, density})`, one renderer per type | yes |
| `blocks.css` | every block's look, in `--u` units | yes |
| `scene.mjs` | `scene(board)`: Excalidraw element skeletons for the editable file in the notes; `files(board)`: the custom pictures in it | no |
| `svg.mjs` | `cleanSvg(text)`: a custom picture made safe (below); run by the room on every picture it keeps | no |

The edits that change a board, and their checks, live beside the room in `src/ops.js` (pure, run by the room and by the
tests). The page (`board.mjs`) only renders boards it is sent and sends edits back.

## How a block draws

`draw()` keeps the block's element and everything in it keyed by id, so one change moves only what changed: an item
added comes in, one removed leaves, the rest glide to where they now go (`translate` transitions; `put()` records the
final place in `data-x`/`data-y` for the cursor). It returns the elements of the items in `changed`, which `view.mjs`
rings in the changer's color for a few seconds. A block that a command made is ringed once, not again for each item
that command then adds.

Sizes are in `--u`, one unit times the board's density, so a fuller board shrinks every block alike. Keep type at 14u
or more and lines at 2u or more: the board is seen through a compressed Meet share, where hairlines and small type are
lost. Violet (`--hermes`) means "just changed" and nothing else. Chart series use `SERIES` and mind map branches
`BRANCHES` (both checked for color blindness), and text is always ink or muted, never a series color.

## A custom picture

For what no block can show (how a system's parts connect, a one-off diagram), the edit model calls `sketch` with a
brief. The brain adds a `sketch` block at once, with `drawing` set, and the page shows "Hermes is drawing this" with the
brief. A thread on the mini (`board_brain.draw_sketch`) streams the picture from Sonnet and sends what it has every
1.2 s, so the picture fills in, then sends it whole (or `failed`) and the line "Drew …". A later "in that picture, add
…" sends the current SVG and what it shows with the change, and sends only the whole new picture, so the old one stays
up (marked "Redrawing") until then, and stays if the redraw fails. Only Hermes
can send a picture: the board link's people can move, retitle or remove the block, never set its SVG. Keeping a
finished picture patches the undo snapshots that hold the same drawing in place, so undo never brings back a half-drawn
one, and it is not an undo step of its own.

The SVG is untrusted (the model writes it from what people said), and the board is shown to everyone in the call and on
its link. So `cleanSvg()` reads it tag by tag and writes it again from an allowlist: the shapes, `text` and `tspan`,
`g`, `defs` and `marker`, each with plain attributes whose values are checked (numbers, colors, path data, transforms,
`url(#id)` to a marker in the same picture). Everything else goes, with what it holds: scripts, styles, event handlers,
`href`s, images, `foreignObject`, filters, animation, entities and any outside reference. Anything before the `<svg>`
is never read, comments are dropped, and a declaration or processing instruction (`<!DOCTYPE`, `<!ENTITY`, `<?`) inside
the picture refuses it whole. It caps the input at 64 KB, the output at 20,000 characters, 600 elements, 16 deep (64
open, kept or not), and keeps markers to the ends of lines and one level deep, since a browser paints a marker's own
markers again for each one. Every value is checked in one pass, so no long value can make the room slow.
The page then shows the result only as an `<img>` from a blob URL, where nothing in an SVG can run or load anything,
with the board's font (fetched once from jsDelivr) inlined as a data URL. The page's CSP already allowed `blob:` and
`data:` images and jsDelivr connections, so it needs nothing new.

## Adding a kind of block

1. `model.mjs`: add the type to `TYPES`, its settings and item fields to `FIELDS`, and a default title to `TYPE_TITLES`.
2. `src/ops.js`: check any new field in `settle()` (block) or `fill()` (item), and word it in `facts()` so a change says
   what it did.
3. `sizes.mjs`: add its `NEEDS` entry: `minW`, `idealW`, `maxW`, `minH`, `maxH`, and `h(width)`.
4. `blocks.mjs`: write `drawX(body, block, opts)`, add it to `DRAW`, a count line to `META` and an empty-block prompt to
   `ASK`. Key every part by id with `keyed()` and place with `put()`.
5. `blocks.css`: its look, in `--u` units.
6. `scene.mjs`: its Excalidraw skeleton, in `DRAW`.
7. `mini/meeting_board.py`: teach the model the type in `SYSTEM` and the tools' enums, and read it into the notes in
   `_block_lines()`.
8. Tests: `bot/test/ops.test.mjs` (fields and refusals), `bot/test/view.test.mjs` (sizes and the exported file),
   `mini/tests/test_meeting_board.py` (the notes).

// What a section's items are. Shared by the board room's edits (src/ops.js) and the board page, so both agree that
// "Risks" holds risks whoever made it.
export const KINDS = ['notes', 'goals', 'risks', 'actions', 'decisions', 'pros', 'cons'];

// A section given no kind gets one from its title, so "Risks" is red whoever made it.
const GUESSES = [
  ['actions', /\b(?:action items?|actions?|next steps?|to-?dos?|tasks?|follow-?ups?|owners?)\b/i],
  ['decisions', /\b(?:decisions?|decided|agreed)\b/i],
  ['risks', /\b(?:risks?|concerns?|blockers?|worries)\b/i],
  ['cons', /\b(?:cons|downsides?|drawbacks?|didn'?t go well|went badly|to improve)\b/i],
  ['pros', /\b(?:pros|upsides?|benefits?|went well)\b/i],
  ['goals', /\b(?:goals?|objectives?|outcomes?|targets?|wins?|okrs?)\b/i],
];
export const guessKind = (title) => GUESSES.find(([, words]) => words.test(String(title || '')))?.[0] || 'notes';
export const kindOf = (section) => (KINDS.includes(section?.kind) ? section.kind : guessKind(section?.title));

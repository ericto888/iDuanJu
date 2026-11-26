// Dice-coefficient string similarity. Own code, GPL-3.0.
function bigrams(s) {
  const m = new Map();
  for (let i = 0; i < s.length - 1; i++) { const k = s.substr(i, 2); m.set(k, (m.get(k) || 0) + 1); }
  return m;
}

export function compareTwoStrings(x, y) {
  const a = String(x).replace(/\s+/g, ''), b = String(y).replace(/\s+/g, '');
  if (a === b) return 1;
  if (a.length < 2 || b.length < 2) return 0;
  const m = bigrams(a);
  let hit = 0;
  for (let i = 0; i < b.length - 1; i++) {
    const k = b.substr(i, 2), n = m.get(k) || 0;
    if (n > 0) { m.set(k, n - 1); hit++; }
  }
  return (2 * hit) / (a.length + b.length - 2);
}

export function findBestMatch(main, targets) {
  const ratings = targets.map(target => ({ target, rating: compareTwoStrings(main, target) }));
  let bestMatchIndex = 0;
  ratings.forEach((r, i) => { if (r.rating > ratings[bestMatchIndex].rating) bestMatchIndex = i; });
  return { ratings, bestMatch: ratings[bestMatchIndex], bestMatchIndex };
}

export default { compareTwoStrings, findBestMatch };

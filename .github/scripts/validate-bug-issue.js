'use strict';

const BUG_REPORT_RULES_EFFECTIVE_AT = '2026-11-25T14:30:00Z';

const REQUIRED_FIELDS = [
  { id: 'os', names: ['系统版本'] },
  { id: 'app', names: ['软件版本'] },
  { id: 'description', names: ['Bug描述', 'Bug 描述'] },
];

function normalizeLabelName(label) {
  if (!label) return '';
  if (typeof label === 'string') return label.trim().toLowerCase();
  return String(label.name || '').trim().toLowerCase();
}

function labelNames(issue) {
  return (issue.labels || []).map(normalizeLabelName).filter(Boolean);
}

function isPullRequest(issue) {
  return Boolean(issue && issue.pull_request);
}

function isHistorical(issue, effectiveAt) {
  const created = Date.parse(issue && issue.created_at);
  const effective = Date.parse(effectiveAt || BUG_REPORT_RULES_EFFECTIVE_AT);
  if (Number.isNaN(created) || Number.isNaN(effective)) return true;
  return created < effective;
}

function hasBugTitle(title) {
  return /^\s*\[(bug|缺陷)\]/i.test(String(title || ''));
}

function hasFeatureTitle(title) {
  return /^\s*\[(功能建议|feature(?:\s*request)?)\]/i.test(String(title || ''));
}

function parseFormSections(body) {
  const text = String(body || '').replace(/\r\n/g, '\n');
  const sections = {};
  const heading = /^###\s+(.+?)\s*$/gm;
  const matches = [];
  let match;
  while ((match = heading.exec(text)) !== null) {
    matches.push({
      name: match[1].trim(),
      start: match.index + match[0].length,
      at: match.index,
    });
  }
  for (let i = 0; i < matches.length; i += 1) {
    const end = i + 1 < matches.length ? matches[i + 1].at : text.length;
    sections[matches[i].name] = text.slice(matches[i].start, end).trim();
  }
  return sections;
}

function hasBugFormHeadings(body) {
  const names = new Set(Object.keys(parseFormSections(body)));
  const hasOs = names.has('系统版本');
  const hasApp = names.has('软件版本');
  const hasDesc = names.has('Bug描述') || names.has('Bug 描述');
  return [hasOs, hasApp, hasDesc].filter(Boolean).length >= 2;
}

function isBugReport(issue) {
  const labels = labelNames(issue);
  if (labels.includes('bug')) return true;
  if (hasBugTitle(issue && issue.title)) return true;
  if (hasBugFormHeadings((issue && issue.body) || '')) return true;
  return false;
}

function isProtectedNonBug(issue) {
  if (hasFeatureTitle(issue && issue.title)) return true;
  const labels = labelNames(issue);
  if (
    labels.includes('enhancement') &&
    !labels.includes('bug') &&
    !hasBugTitle(issue && issue.title) &&
    !hasBugFormHeadings((issue && issue.body) || '')
  ) {
    return true;
  }
  return false;
}

function isEmptyValue(value) {
  const text = String(value || '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/\r/g, '')
    .trim();
  if (!text) return true;
  return /^_no response_$/i.test(text);
}

function parseLabeledValues(body) {
  const values = {};
  const text = String(body || '').replace(/\r\n/g, '\n');
  const line = /^\s*(?:[-*]\s+)?(?:\*\*)?(系统版本|软件版本|Bug\s*描述|Bug描述)(?:\*\*)?\s*[:：]\s*(.*)$/gmu;
  let match;
  while ((match = line.exec(text)) !== null) {
    const name = match[1].replace(/\s+/g, ' ').trim();
    const value = (match[2] || '').trim();
    if (!Object.prototype.hasOwnProperty.call(values, name) || isEmptyValue(values[name])) {
      values[name] = value;
    }
  }
  return values;
}

function fieldValue(body, names) {
  const sections = parseFormSections(body);
  for (const name of names) {
    if (Object.prototype.hasOwnProperty.call(sections, name)) {
      return sections[name];
    }
  }
  const labeled = parseLabeledValues(body);
  const labeledKeys = Object.keys(labeled);
  for (const name of names) {
    if (Object.prototype.hasOwnProperty.call(labeled, name)) {
      return labeled[name];
    }
    const normalized = name.replace(/\s+/g, '');
    const found = labeledKeys.find((key) => key.replace(/\s+/g, '') === normalized);
    if (found) return labeled[found];
  }
  return null;
}

function missingRequiredFields(body) {
  return REQUIRED_FIELDS.filter((field) => {
    const value = fieldValue(body, field.names);
    return value == null || isEmptyValue(value);
  }).map((field) => field.names[0]);
}

function decideBugIssueAction({ issue, effectiveAt } = {}) {
  const target = issue || {};
  if (isPullRequest(target)) {
    return { close: false, reason: 'pull_request' };
  }
  if (isHistorical(target, effectiveAt)) {
    return { close: false, reason: 'historical' };
  }
  if (
    isProtectedNonBug(target) &&
    !labelNames(target).includes('bug') &&
    !hasBugTitle(target.title)
  ) {
    return { close: false, reason: 'not_bug' };
  }
  if (!isBugReport(target)) {
    return { close: false, reason: 'not_bug' };
  }
  const missing = missingRequiredFields(target.body);
  if (missing.length) {
    return { close: true, reason: 'missing_fields', missing };
  }
  return { close: false, reason: 'complete' };
}

module.exports = {
  BUG_REPORT_RULES_EFFECTIVE_AT,
  decideBugIssueAction,
  missingRequiredFields,
  isBugReport,
  isEmptyValue,
};

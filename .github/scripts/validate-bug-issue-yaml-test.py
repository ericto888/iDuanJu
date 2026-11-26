#!/usr/bin/env python3
from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[2]
bug = yaml.safe_load((root / ".github/ISSUE_TEMPLATE/bug_report.yml").read_text(encoding="utf-8"))
feature = yaml.safe_load((root / ".github/ISSUE_TEMPLATE/feature_request.yml").read_text(encoding="utf-8"))
workflow = yaml.safe_load((root / ".github/workflows/validate-bug-issue.yml").read_text(encoding="utf-8"))
config_path = root / ".github/ISSUE_TEMPLATE/config.yml"

assert bug["name"] == "Bug 反馈"
assert "缺项不予受理" in bug["description"] and "直接关闭" in bug["description"]
assert bug["labels"] == ["bug"]
intro = bug["body"][0]
assert intro["type"] == "markdown"
assert "系统版本" in intro["attributes"]["value"]
assert "软件版本" in intro["attributes"]["value"]
assert "Bug 描述" in intro["attributes"]["value"]
assert "不予受理" in intro["attributes"]["value"]
assert "直接关闭" in intro["attributes"]["value"]

required = {}
optional = []
for item in bug["body"]:
    if item["type"] in {"input", "textarea"}:
        label = item["attributes"]["label"]
        if item.get("validations", {}).get("required"):
            required[label] = item
        else:
            optional.append(label)

assert set(required) == {"系统版本", "软件版本", "Bug 描述"}, required
assert "复现步骤" in optional
assert "截图或录屏" in optional

assert feature["name"] == "功能建议"
assert feature["labels"] == ["enhancement"]
feature_required = [
    item["attributes"]["label"]
    for item in feature["body"]
    if item["type"] in {"input", "textarea"} and item.get("validations", {}).get("required")
]
assert "系统版本" not in feature_required
assert "软件版本" not in feature_required
assert "Bug 描述" not in feature_required

if config_path.exists():
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    assert config.get("blank_issues_enabled", True) is True

# PyYAML 1.1 treats bare `on` as boolean true; the workflow file keeps standard Actions syntax.
on_block = workflow.get("on", workflow.get(True))
assert on_block == {"issues": {"types": ["opened"]}}
assert workflow["permissions"] == {"contents": "read", "issues": "write"}
job = workflow["jobs"]["validate"]
assert "github.event.issue.pull_request" in str(job.get("if", ""))
steps = job["steps"]
assert steps[0]["uses"].startswith("actions/checkout@")
assert steps[0]["with"]["persist-credentials"] is False
assert steps[1]["uses"].startswith("actions/github-script@")
script = steps[1]["with"]["script"]
assert "decideBugIssueAction" in script
assert "state_reason: 'not_planned'" in script or 'state_reason: "not_planned"' in script
assert "createComment" not in script
assert "issues.createComment" not in script
assert "eval(" not in script
assert "exec(" not in script
# Untrusted issue body must not be concatenated into a shell command.
for step in steps:
    run = step.get("run")
    if run:
        assert "github.event.issue" not in run
        assert "issue.body" not in run

print("ok yaml checks")

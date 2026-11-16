#!/usr/bin/env python3
"""PostToolUse hook: flag risky patterns that Claude just ADDED to Sorrel.

Compares the new text against the old text (or the committed file), so code
that was already there isn't flagged again. Exit 2 shows the findings to Claude.
"""
import json
import os
import re
import subprocess
import sys

PATTERNS = [
    (r"NSAllowsArbitraryLoads|NSExceptionAllowsInsecureHTTPLoads",
     "weakens App Transport Security"),
    (r"URLCredential\s*\(\s*trust:|SecTrustSetExceptions|serverTrust",
     "custom TLS certificate handling (could bypass certificate checks)"),
    (r"addScriptMessageHandler|WKScriptMessageHandler",
     "page-to-app JavaScript bridge (rule 4)"),
    (r"allowFileAccessFromFileURLs|allowUniversalAccessFromFileURLs|allowingReadAccessTo",
     "gives web content file:// access"),
    (r"WKWebsiteDataStore\s*\.\s*default\s*\(",
     "persistent data store (private windows must stay non-persistent)"),
    (r"isFraudulentWebsiteWarningEnabled\s*=\s*false",
     "turns off fraudulent-site warnings"),
    (r"javaScriptCanOpenWindowsAutomatically\s*=\s*true",
     "lets pages open pop-ups without a click"),
    (r"\.grant\b",
     "grants a permission (never auto-grant)"),
    (r"removeAllContentRuleLists|removeContentRuleList",
     "removes content-blocking rules"),
    (r"(evaluateJavaScript|callAsyncJavaScript)\s*\(\s*\"[^\"\n]*\\\(",
     "interpolates a Swift value into JavaScript source (injection risk)"),
    (r"URLSession|URLRequest\s*\(",
     "new network request (rule 2: no new outbound calls)"),
    (r"sorrel-insecure",
     "touches the insecure-site bypass link"),
    (r"disable-library-validation|allow-unsigned-executable-memory|cs\.allow-jit"
     r"|get-task-allow|temporary-exception|files\.all|network\.server",
     "adds a powerful entitlement (rule 3)"),
]

PATH_NOTES = [
    (r"(^|/)Sources/(SorrelUpdateCore|SorrelUpdater)/",
     "updater code: signature verification must never be weakened"),
    (r"(^|/)ChromeCompat\.swift$",
     "Proton chrome.runtime bridge must stay limited to exact origins"),
    (r"\.entitlements$|(^|/)Info\.plist$",
     "app security configuration changed"),
]

SCANNED = (".swift", ".plist", ".entitlements", ".js", ".json", ".html", ".sh")


def committed_text(rel_path):
    try:
        return subprocess.run(["git", "show", f"HEAD:{rel_path}"],
                              capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    tool = data.get("tool_name", "")
    ti = data.get("tool_input") or {}
    path = ti.get("file_path") or ""
    if not path.endswith(SCANNED):
        return 0

    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    rel = os.path.relpath(path, project) if os.path.isabs(path) else path
    if rel.startswith("vendor/") or rel.startswith(".claude/"):
        return 0

    pairs = []  # (old_text, new_text)
    if tool == "Edit":
        pairs.append((ti.get("old_string", ""), ti.get("new_string", "")))
    elif tool == "MultiEdit":
        for e in ti.get("edits") or []:
            pairs.append((e.get("old_string", ""), e.get("new_string", "")))
    elif tool == "Write":
        os.chdir(project)
        pairs.append((committed_text(rel), ti.get("content", "")))
    else:
        return 0

    findings = []
    for pattern, why in PATTERNS:
        rx = re.compile(pattern)
        added = sum(max(0, len(rx.findall(new)) - len(rx.findall(old)))
                    for old, new in pairs)
        if added:
            findings.append(f"- {why}")

    notes = [why for pattern, why in PATH_NOTES if re.search(pattern, rel)]
    if not findings and not notes:
        return 0

    msg = [f"Security review needed for your edit to {rel}:"]
    msg += findings
    msg += [f"- Note: {n}" for n in notes]
    msg.append("Check this against the Security invariants in CLAUDE.md. If it's "
               "intentional and safe, carry on, and list it in your final summary "
               "so the user can review it. If not, undo it.")
    print("\n".join(msg), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

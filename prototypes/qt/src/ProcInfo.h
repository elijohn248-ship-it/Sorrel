// Read-only facts about Birch's own process tree: which helper processes exist,
// whether they are sandboxed, and how much memory the tree uses. Tests only.
#pragma once
#include <QList>
#include <QString>

namespace Birch {

struct ProcRow {
    qint64 pid = 0;
    qint64 ppid = 0;
    QString exe;
    QString type;          // Chromium --type= (Linux: from /proc/<pid>/cmdline; Windows: filled by the harness)
    QString integrity;     // Windows: untrusted/low/medium/high/system or "unreadable"
    int restricted = -1;   // Windows: restricted token (1/0, -1 unknown)
    int appContainer = -1; // Windows
    int inJob = -1;        // Windows
    int seccomp = -1;      // Linux: 0 none, 1 strict, 2 filter
    int pidNamespaceDepth = -1;  // Linux: entries in NSpid (2 = own PID namespace)
    bool noSandboxSwitch = false;
    double privateMb = -1; // Windows: PrivateUsage; Linux: RssAnon
    double residentMb = -1;
};

QList<ProcRow> processTree(qint64 root);  // root first, then all descendants
bool processAlive(qint64 pid);
bool killProcess(qint64 pid);

} // namespace Birch

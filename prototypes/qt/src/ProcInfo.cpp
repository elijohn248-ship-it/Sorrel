#include "ProcInfo.h"

#include <QDir>
#include <QFile>
#include <QSet>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <vector>
#else
#include <cerrno>
#include <csignal>
#include <sys/types.h>
#include <unistd.h>
#endif

namespace Birch {

namespace {

struct Entry {
    qint64 pid;
    qint64 ppid;
    QString exe;
};

void parseCommandLine(ProcRow &row, const QString &cmd)
{
    const int at = int(cmd.indexOf(QLatin1String("--type=")));
    if (at >= 0) {
        int end = at + 7;
        while (end < cmd.size() && !cmd[end].isSpace() && cmd[end] != QChar(0) && cmd[end] != QLatin1Char('"'))
            ++end;
        row.type = cmd.mid(at + 7, end - at - 7);
        const int sub = int(cmd.indexOf(QLatin1String("--utility-sub-type=")));
        if (sub >= 0) {
            int e2 = sub + 19;
            while (e2 < cmd.size() && !cmd[e2].isSpace() && cmd[e2] != QChar(0) && cmd[e2] != QLatin1Char('"'))
                ++e2;
            row.type += QLatin1Char('/') + cmd.mid(sub + 19, e2 - sub - 19);
        }
    } else {
        row.type = QStringLiteral("browser");
    }
    row.noSandboxSwitch = cmd.contains(QLatin1String("--no-sandbox"));
}

#ifdef Q_OS_WIN
QList<Entry> allProcesses()
{
    QList<Entry> out;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return out;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            out.append({qint64(pe.th32ProcessID), qint64(pe.th32ParentProcessID),
                        QString::fromWCharArray(pe.szExeFile)});
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return out;
}

using NtQueryInformationProcessFn = LONG(NTAPI *)(HANDLE, ULONG, PVOID, ULONG, PULONG);

QString commandLine(HANDLE h)
{
    static const auto fn = reinterpret_cast<NtQueryInformationProcessFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess")));
    if (!fn)
        return QString();
    const ULONG kProcessCommandLineInformation = 60;
    ULONG len = 0;
    fn(h, kProcessCommandLineInformation, nullptr, 0, &len);
    if (len == 0)
        return QString();
    std::vector<BYTE> buf(len);
    if (fn(h, kProcessCommandLineInformation, buf.data(), len, &len) < 0)
        return QString();
    const auto *us = reinterpret_cast<const UNICODE_STRING *>(buf.data());
    return QString::fromWCharArray(us->Buffer, int(us->Length / sizeof(wchar_t)));
}

void fill(ProcRow &row)
{
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(row.pid));
    if (!h) {
        row.integrity = QStringLiteral("unreadable");
        return;
    }
    parseCommandLine(row, commandLine(h));
    HANDLE tok = nullptr;
    if (OpenProcessToken(h, TOKEN_QUERY, &tok)) {
        DWORD len = 0;
        GetTokenInformation(tok, TokenIntegrityLevel, nullptr, 0, &len);
        std::vector<BYTE> buf(len ? len : 1);
        if (len && GetTokenInformation(tok, TokenIntegrityLevel, buf.data(), len, &len)) {
            const auto *tml = reinterpret_cast<const TOKEN_MANDATORY_LABEL *>(buf.data());
            const DWORD rid = *GetSidSubAuthority(tml->Label.Sid, DWORD(*GetSidSubAuthorityCount(tml->Label.Sid) - 1));
            row.integrity = rid < 0x1000 ? QStringLiteral("untrusted")
                : rid < 0x2000           ? QStringLiteral("low")
                : rid < 0x3000           ? QStringLiteral("medium")
                : rid < 0x4000           ? QStringLiteral("high")
                                         : QStringLiteral("system");
        }
        row.restricted = IsTokenRestricted(tok) ? 1 : 0;
        DWORD ac = 0;
        if (GetTokenInformation(tok, TokenIsAppContainer, &ac, sizeof(ac), &len))
            row.appContainer = ac ? 1 : 0;
        CloseHandle(tok);
    } else {
        row.integrity = QStringLiteral("token-denied");
    }
    BOOL job = FALSE;
    if (IsProcessInJob(h, nullptr, &job))
        row.inJob = job ? 1 : 0;
    PROCESS_MEMORY_COUNTERS_EX pmc{};
    if (GetProcessMemoryInfo(h, reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&pmc), sizeof(pmc))) {
        row.privateMb = double(pmc.PrivateUsage) / 1048576.0;
        row.residentMb = double(pmc.WorkingSetSize) / 1048576.0;
    }
    CloseHandle(h);
}
#else
QString readText(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    return QString::fromUtf8(f.readAll());
}

QList<Entry> allProcesses()
{
    QList<Entry> out;
    const QStringList dirs = QDir(QStringLiteral("/proc")).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &d : dirs) {
        bool ok = false;
        const qint64 pid = d.toLongLong(&ok);
        if (!ok)
            continue;
        const QString stat = readText(QStringLiteral("/proc/%1/stat").arg(pid));
        const int open = int(stat.indexOf(QLatin1Char('('))), close = int(stat.lastIndexOf(QLatin1Char(')')));
        if (open < 0 || close < 0)
            continue;
        const QStringList rest = stat.mid(close + 2).split(QLatin1Char(' '));
        if (rest.size() < 2 || rest[0] == QLatin1String("Z"))
            continue;
        out.append({pid, rest[1].toLongLong(), stat.mid(open + 1, close - open - 1)});
    }
    return out;
}

void fill(ProcRow &row)
{
    QString cmd = readText(QStringLiteral("/proc/%1/cmdline").arg(row.pid));
    cmd.replace(QChar(0), QLatin1Char(' '));
    parseCommandLine(row, cmd);
    const QStringList lines = readText(QStringLiteral("/proc/%1/status").arg(row.pid)).split(QLatin1Char('\n'));
    for (const QString &l : lines) {
        const QStringList parts = l.simplified().split(QLatin1Char(' '));
        if (parts.size() < 2)
            continue;
        if (parts[0] == QLatin1String("Seccomp:"))
            row.seccomp = parts[1].toInt();
        else if (parts[0] == QLatin1String("NSpid:"))
            row.pidNamespaceDepth = int(parts.size() - 1);
        else if (parts[0] == QLatin1String("VmRSS:"))
            row.residentMb = parts[1].toDouble() / 1024.0;
        else if (parts[0] == QLatin1String("RssAnon:"))
            row.privateMb = parts[1].toDouble() / 1024.0;
    }
}
#endif

} // namespace

QList<ProcRow> processTree(qint64 root)
{
    const QList<Entry> all = allProcesses();
    QList<ProcRow> rows;
    QList<qint64> queue{root};
    QSet<qint64> seen{root};
    while (!queue.isEmpty()) {
        const qint64 pid = queue.takeFirst();
        ProcRow row;
        row.pid = pid;
        for (const Entry &e : all) {
            if (e.pid == pid) {
                row.ppid = e.ppid;
                row.exe = e.exe;
            }
            if (e.ppid == pid && !seen.contains(e.pid)) {
                seen.insert(e.pid);
                queue.append(e.pid);
            }
        }
        fill(row);
        rows.append(row);
    }
    return rows;
}

bool processAlive(qint64 pid)
{
    if (pid <= 0)
        return false;
#ifdef Q_OS_WIN
    HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid));
    if (!h)
        return GetLastError() == ERROR_ACCESS_DENIED;
    const bool alive = WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
    CloseHandle(h);
    return alive;
#else
    for (const Entry &e : allProcesses())
        if (e.pid == pid)
            return true;
    return false;
#endif
}

bool killProcess(qint64 pid)
{
    if (pid <= 0)
        return false;
#ifdef Q_OS_WIN
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, DWORD(pid));
    if (!h)
        return false;
    const bool ok = TerminateProcess(h, 1) != 0;
    CloseHandle(h);
    return ok;
#else
    return ::kill(pid_t(pid), SIGKILL) == 0;
#endif
}

} // namespace Birch

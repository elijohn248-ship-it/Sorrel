// Test log lines: "<area>: expected=... got=..." (shared rule 7). Counts, flags
// and fixture origins only; never page text from real sites.
#pragma once
#include <QFile>
#include <QString>
#include <QTextStream>
#include <cstdio>

namespace Birch {

inline void log(const QString &line)
{
    const QByteArray bytes = line.toUtf8();
    std::fprintf(stderr, "%s\n", bytes.constData());
    std::fflush(stderr);
    static const QString path = qEnvironmentVariable("BIRCH_LOG");
    if (!path.isEmpty()) {
        QFile f(path);
        if (f.open(QIODevice::Append | QIODevice::Text)) {
            f.write(bytes);
            f.write("\n");
        }
    }
}

inline QString yesNo(bool b) { return b ? QStringLiteral("1") : QStringLiteral("0"); }

// One expected/got line. The harness compares the two tokens.
inline void check(const QString &area, const QString &what, const QString &expected, const QString &got,
                  const QString &extra = QString())
{
    log(QStringLiteral("%1: %2 expected=%3 got=%4%5")
            .arg(area, what, expected, got, extra.isEmpty() ? QString() : QStringLiteral(" ") + extra));
}

} // namespace Birch

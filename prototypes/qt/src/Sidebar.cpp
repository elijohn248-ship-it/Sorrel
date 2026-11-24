#include "Sidebar.h"

#include <QLabel>
#include <QLinearGradient>
#include <QListWidget>
#include <QPainter>
#include <QPainterPath>
#include <QPropertyAnimation>
#include <QRandomGenerator>
#include <QVBoxLayout>
#include <QtMath>

namespace Birch {

namespace {

// OKLab, as on the Mac (ThemeLook.swift), so blends between colours stay even.
struct Lab {
    double L, a, b;
};

double toLinear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }
double toSrgb(double c)
{
    c = qBound(0.0, c, 1.0);
    return c <= 0.0031308 ? 12.92 * c : 1.055 * std::pow(c, 1.0 / 2.4) - 0.055;
}

Lab toLab(const QColor &c)
{
    const double r = toLinear(c.redF()), g = toLinear(c.greenF()), b = toLinear(c.blueF());
    const double l = std::cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const double m = std::cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const double s = std::cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s};
}

QColor fromLab(const Lab &x)
{
    const double l = std::pow(x.L + 0.3963377774 * x.a + 0.2158037573 * x.b, 3);
    const double m = std::pow(x.L - 0.1055613458 * x.a - 0.0638541728 * x.b, 3);
    const double s = std::pow(x.L - 0.0894841775 * x.a - 1.2914855480 * x.b, 3);
    return QColor::fromRgbF(float(toSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
                            float(toSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
                            float(toSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)));
}

QColor mixLab(const QColor &a, const QColor &b, double t)
{
    const Lab x = toLab(a), y = toLab(b);
    return fromLab({x.L + (y.L - x.L) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t});
}

} // namespace

Sidebar::Sidebar(bool isPrivate, QWidget *parent) : QWidget(parent)
{
    // Birch's tile colours (lavender -> sky -> mint); private windows go dark.
    m_colors = isPrivate ? QList<QColor>{QColor(0x2b, 0x26, 0x3d), QColor(0x1d, 0x22, 0x33), QColor(0x22, 0x2e, 0x2a)}
                         : QList<QColor>{QColor(0xd6, 0xcf, 0xf5), QColor(0xc8, 0xe6, 0xf7), QColor(0xcf, 0xf2, 0xdf)};
    setAttribute(Qt::WA_TranslucentBackground);
    setAutoFillBackground(false);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(10, 12, 10, 12);
    layout->setSpacing(8);
    m_address = new QLabel(this);
    m_address->setObjectName(QStringLiteral("address"));
    m_address->setTextInteractionFlags(Qt::NoTextInteraction);
    const QString fg = isPrivate ? QStringLiteral("#eeeeff") : QStringLiteral("#1d1f26");
    const QString pill = isPrivate ? QStringLiteral("rgba(255,255,255,0.10)") : QStringLiteral("rgba(255,255,255,0.55)");
    m_address->setStyleSheet(QStringLiteral("QLabel#address{background:%1;color:%2;border-radius:9px;padding:7px 10px;"
                                            "font-size:12px;}")
                                 .arg(pill, fg));
    layout->addWidget(m_address);
    m_tabs = new QListWidget(this);
    m_tabs->setFrameShape(QFrame::NoFrame);
    m_tabs->setAttribute(Qt::WA_TranslucentBackground);
    m_tabs->viewport()->setAutoFillBackground(false);
    m_tabs->setStyleSheet(QStringLiteral("QListWidget{background:transparent;color:%1;font-size:13px;}"
                                         "QListWidget::item{padding:6px 8px;border-radius:8px;}"
                                         "QListWidget::item:selected{background:%2;color:%1;}"
                                         "QListWidget::item:hover{background:rgba(255,255,255,0.25);}")
                              .arg(fg, pill));
    layout->addWidget(m_tabs, 1);

    m_anim = new QPropertyAnimation(this, "pos", this);
    m_clock.start();
    connect(m_anim, &QPropertyAnimation::valueChanged, this, [this](const QVariant &) {
        m_frameTimes.append(m_clock.nsecsElapsed());
    });
    connect(m_anim, &QPropertyAnimation::finished, this, [this]() {
        MotionStats s;
        s.frames = int(m_frameTimes.size());
        if (m_frameTimes.size() >= 2) {
            s.durationMs = double(m_frameTimes.last() - m_frameTimes.first()) / 1e6;
            for (qsizetype i = 1; i < m_frameTimes.size(); ++i)
                s.maxGapMs = qMax(s.maxGapMs, double(m_frameTimes[i] - m_frameTimes[i - 1]) / 1e6);
            s.meanGapMs = s.durationMs / double(m_frameTimes.size() - 1);
        }
        m_stats = s;
    });
}

void Sidebar::setFloating(bool floating)
{
    m_floating = floating;
    update();
}

QPropertyAnimation *Sidebar::slideTo(int x, bool arriving)
{
    m_anim->stop();
    m_frameTimes.clear();
    // Same idea as the Mac's Motion curves: "settle" when arriving, "leave" when going.
    m_anim->setDuration(arriving ? 260 : 180);
    m_anim->setEasingCurve(arriving ? QEasingCurve(QEasingCurve::OutCubic) : QEasingCurve(QEasingCurve::InCubic));
    m_anim->setStartValue(pos());
    m_anim->setEndValue(QPoint(x, pos().y()));
    m_anim->start();
    return m_anim;
}

QImage Sidebar::makeGrainTile(qreal dpr) const
{
    const int side = int(128 * dpr);
    QImage tile(side, side, QImage::Format_ARGB32_Premultiplied);
    tile.fill(Qt::transparent);
    QRandomGenerator rng(42);  // fixed seed: the grain never shimmers between repaints
    for (int y = 0; y < side; ++y) {
        auto *line = reinterpret_cast<QRgb *>(tile.scanLine(y));
        for (int x = 0; x < side; ++x) {
            const quint32 r = rng.bounded(1000u);
            if (r < 500)
                continue;
            const int alpha = int(rng.bounded(90u));
            const int v = (r & 1) ? 255 : 0;
            line[x] = qPremultiply(qRgba(v, v, v, alpha));
        }
    }
    tile.setDevicePixelRatio(dpr);
    return tile;
}

void Sidebar::paintEvent(QPaintEvent *)
{
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    const QRectF r = m_floating ? QRectF(rect()).adjusted(6, 6, -6, -6) : QRectF(rect());
    QPainterPath path;
    if (m_floating)
        path.addRoundedRect(r, 12, 12);
    else
        path.addRect(r);

    // 16 stops, half linear / half smoothstep, mixed in OKLab (as on the Mac).
    QLinearGradient g(r.topLeft(), r.bottomRight());
    const int stops = 16;
    for (int i = 0; i < stops; ++i) {
        const double t = double(i) / (stops - 1);
        const double s = 0.5 * t + 0.5 * (t * t * (3 - 2 * t));
        const double seg = s * double(m_colors.size() - 1);
        const int k = qMin(int(seg), int(m_colors.size()) - 2);
        g.setColorAt(t, mixLab(m_colors[k], m_colors[k + 1], seg - k));
    }
    p.fillPath(path, g);

    const qreal dpr = devicePixelRatioF();
    if (m_grainTile.isNull() || !qFuzzyCompare(m_grainTile.devicePixelRatio(), dpr))
        m_grainTile = makeGrainTile(dpr);
    p.save();
    p.setClipPath(path);
    p.setOpacity(m_grain * 0.32);
    p.fillRect(r, QBrush(m_grainTile));
    p.restore();

    if (m_floating) {
        p.setPen(QPen(QColor(0, 0, 0, 40), 1));
        p.drawPath(path);
    }
}

} // namespace Birch

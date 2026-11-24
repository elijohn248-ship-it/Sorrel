// Arc-style sidebar drawn natively with Qt Widgets: a 16-stop gradient in the
// space's colours, a grain tile on top, and an overlay mode that slides in when
// the pointer reaches the window's left edge. Prototype for gate 9 only.
#pragma once
#include <QColor>
#include <QElapsedTimer>
#include <QImage>
#include <QList>
#include <QWidget>

class QLabel;
class QListWidget;
class QPropertyAnimation;
class QVBoxLayout;

namespace Birch {

class Sidebar : public QWidget {
    Q_OBJECT
public:
    explicit Sidebar(bool isPrivate, QWidget *parent = nullptr);
    QLabel *address() const { return m_address; }
    QListWidget *tabs() const { return m_tabs; }
    void setFloating(bool floating);  // overlay (hidden mode) draws rounded with a shadow edge
    bool isFloating() const { return m_floating; }

    // Slide to x (overlay mode). Returns the animation so tests can sample it.
    QPropertyAnimation *slideTo(int x, bool arriving);

    struct MotionStats {
        int frames = 0;
        double durationMs = 0;
        double meanGapMs = 0;
        double maxGapMs = 0;
    };
    MotionStats lastMotion() const { return m_stats; }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    QImage makeGrainTile(qreal dpr) const;
    QList<QColor> m_colors;
    double m_grain = 0.35;
    bool m_floating = false;
    QLabel *m_address = nullptr;
    QListWidget *m_tabs = nullptr;
    QImage m_grainTile;
    QPropertyAnimation *m_anim = nullptr;
    QElapsedTimer m_clock;
    QList<qint64> m_frameTimes;
    MotionStats m_stats;
};

} // namespace Birch

#pragma once

#include <QColor>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVector>
#include <QtQml/qqmlregistration.h>

#include <deque>

extern "C" {
#include <vterm.h>
}

class Pty;

// What the bytes mean.
//
// libvterm is the VT220/xterm state machine — it parses the stream and
// keeps a grid of cells, and knows nothing about drawing. This wraps it:
// it owns the pty, feeds it what the child writes, keeps the scrollback
// libvterm hands back when lines fall off the top, and turns keystrokes
// into the sequences a program on the far side expects.
//
// The view reads cells from here directly rather than through QML: a
// screenful is a few thousand cells and a repaint asks for all of them.
class Term : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(int rows READ rows NOTIFY sizeChanged)
    Q_PROPERTY(int cols READ cols NOTIFY sizeChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    // Where the shell is, from OSC 7. A terminal that shows the directory
    // in its title bar has to be told; nothing else on the stream says.
    Q_PROPERTY(QString cwd READ cwd NOTIFY cwdChanged)
    Q_PROPERTY(int scrollbackLines READ scrollbackLines NOTIFY scrollbackChanged)
    // How far up the scrollback the view is looking, in lines. 0 is the
    // live screen.
    Q_PROPERTY(int scrollOffset READ scrollOffset WRITE setScrollOffset
               NOTIFY scrollOffsetChanged)
    Q_PROPERTY(bool cursorVisible READ cursorVisible NOTIFY cursorChanged)
    Q_PROPERTY(int cursorRow READ cursorRow NOTIFY cursorChanged)
    Q_PROPERTY(int cursorCol READ cursorCol NOTIFY cursorChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    // Whether the program on the far side asked for mouse events. When it
    // has, the mouse is its business and nothing here may invent keys for
    // it; when it has not, a click is the terminal's to interpret.
    Q_PROPERTY(bool mouseEnabled READ mouseEnabled NOTIFY mouseEnabledChanged)
    Q_PROPERTY(bool altScreen READ altScreen NOTIFY altScreenChanged)

public:
    explicit Term(QObject *parent = nullptr);
    ~Term() override;

    // Colours come from the shell's theme, so they have to be in place
    // before anything is parsed: a default-coloured cell records "the
    // default", and what that resolves to is asked for at paint time.
    Q_INVOKABLE void setPalette(const QColor &fg, const QColor &bg,
                                const QStringList &ansi16);

    Q_INVOKABLE void start(const QStringList &argv = QStringList());
    Q_INVOKABLE void setSize(int rows, int cols);
    Q_INVOKABLE void sendText(const QString &text);
    // key is a Qt::Key, mods a Qt::KeyboardModifiers. `text` is what the
    // keyboard produced, which is what ordinary typing sends.
    Q_INVOKABLE void sendKey(int key, int mods, const QString &text);
    // A click, where the program wants clicks.
    Q_INVOKABLE void sendMouse(int row, int col, int button, bool pressed, int mods);

    // Put the shell's cursor where the pointer is, by sending the arrows
    // that would have taken it there. A terminal has no other way: the
    // line being edited belongs to the shell, which is told about keys and
    // nothing else.
    Q_INVOKABLE void placeCursor(int row, int col);

    Q_INVOKABLE void scrollBy(int lines);
    Q_INVOKABLE void scrollToBottom();

    int rows() const { return m_rows; }
    int cols() const { return m_cols; }
    QString title() const { return m_title; }
    QString cwd() const { return m_cwd; }
    int scrollbackLines() const { return static_cast<int>(m_scrollback.size()); }
    int scrollOffset() const { return m_scrollOffset; }
    void setScrollOffset(int off);
    bool cursorVisible() const { return m_cursorVisible; }
    int cursorRow() const { return m_cursorPos.row; }
    int cursorCol() const { return m_cursorPos.col; }
    bool running() const;
    bool mouseEnabled() const { return m_mouse != 0; }
    bool altScreen() const { return m_altScreen; }

    // For the view. `row` is in view coordinates: 0 is the top visible
    // line, which is a scrollback line when the view is scrolled up.
    bool cellAt(int row, int col, VTermScreenCell *out) const;
    // Both sides of a default colour, resolved.
    QColor toColor(const VTermColor &c, bool background) const;
    QColor defaultFg() const { return m_defaultFg; }
    QColor defaultBg() const { return m_defaultBg; }

    QString textOfRange(int row0, int col0, int row1, int col1) const;

signals:
    void damaged();
    void sizeChanged();
    void titleChanged();
    void cwdChanged();
    void scrollbackChanged();
    void scrollOffsetChanged();
    void cursorChanged();
    void runningChanged();
    void mouseEnabledChanged();
    void altScreenChanged();
    void bell();
    void exited(int code);

private:
    static int onDamage(VTermRect rect, void *user);
    static int onMoveRect(VTermRect dest, VTermRect src, void *user);
    static int onMoveCursor(VTermPos pos, VTermPos oldpos, int visible, void *user);
    static int onSetTermProp(VTermProp prop, VTermValue *val, void *user);
    static int onBell(void *user);
    static int onResize(int rows, int cols, void *user);
    static int onPushLine(int cols, const VTermScreenCell *cells, void *user);
    static int onPopLine(int cols, VTermScreenCell *cells, void *user);
    static int onOsc(int command, VTermStringFragment frag, void *user);
    static void onOutput(const char *s, size_t len, void *user);

    void feed(const QByteArray &data);
    void markDamaged();

    VTerm *m_vt = nullptr;
    VTermScreen *m_screen = nullptr;
    Pty *m_pty = nullptr;

    int m_rows = 24;
    int m_cols = 80;
    QString m_title;
    QString m_cwd;
    QString m_oscPending;
    int m_oscCommand = -1;

    std::deque<QVector<VTermScreenCell>> m_scrollback;
    // Bounded, or a build log is a memory leak with a cursor in it.
    static constexpr int kScrollbackMax = 10000;
    int m_scrollOffset = 0;

    int m_mouse = 0;
    bool m_altScreen = false;

    VTermPos m_cursorPos { 0, 0 };
    bool m_cursorVisible = true;

    QColor m_defaultFg { "#e8e6e3" };
    QColor m_defaultBg { "#1a1a18" };

    // Repaints are coalesced: a program writing a screenful sends dozens
    // of damage rectangles for one visible change, and painting each
    // would spend the frame on work nobody sees.
    QTimer m_repaint;
};

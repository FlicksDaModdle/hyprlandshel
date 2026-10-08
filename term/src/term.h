#pragma once

#include <QColor>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVector>
#include <QtQml/qqmlregistration.h>


#include "htcore.h"

class Pty;

// What the bytes mean.
//
// The emulation is alacritty_terminal — the parser and grid Alacritty runs
// on — built from core/ in Rust and reached through htcore.h. It parses
// the stream, keeps the screen and the scrollback, and turns keys, clicks
// and pastes into what the program on the far side expects for the modes
// it has set. This owns the pty, feeds it what the child writes, and
// answers for the view and QML.
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
    // 1 block, 2 underline, 3 bar — DECSCUSR's numbering. A bar unless the program says otherwise; vim asks for a
    // block in normal mode and a bar in insert, and being told is better
    // than having an opinion.
    Q_PROPERTY(int cursorShape READ cursorShape NOTIFY cursorStyleChanged)
    Q_PROPERTY(bool cursorBlink READ cursorBlink NOTIFY cursorStyleChanged)
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
    // Text from the clipboard: bracketed for a program that asked, so a
    // pasted line is not run as if typed.
    Q_INVOKABLE void paste(const QString &text);
    // Whether the window has the keyboard, for programs that asked to be
    // told (vim and tmux redraw on it).
    Q_INVOKABLE void setFocused(bool focused);
    // The size of a cell in pixels, for programs that ask for it.
    void setCellPixels(int w, int h) { m_cellW = w; m_cellH = h; }
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
    // Deletes a selection out of the line being typed, the way a text box
    // would: the cursor to its end, then a backspace for each character in
    // it. Line ids, inclusive cells. False when the selection is not in the
    // line at the prompt — then nothing is sent.
    bool eraseSelection(qint64 id0, int col0, qint64 id1, int col1);

    Q_INVOKABLE void scrollBy(int lines);
    Q_INVOKABLE void scrollToBottom();

    int rows() const { return m_rows; }
    int cols() const { return m_cols; }
    QString title() const { return m_title; }
    QString cwd() const { return m_cwd; }
    int scrollbackLines() const { return m_st.history; }

    // ── line identity ─────────────────────────────────────────────────
    //
    // A row number counted from the top of the view is not a place in
    // the text: scroll by one and every line has a different number,
    // and a selection stored that way slides up the screen as you
    // scroll — which is exactly what it did.
    //
    // So each line gets an id that never changes. Ids count from the
    // oldest line the scrollback has ever held, including the ones it
    // has since dropped — m_firstLineId is the id of scrollback[0] and
    // grows as lines fall off the far end, so an id stays attached to
    // its own line even when the buffer overflows. The core says how many
    // lines went up off the screen in each feed (ht_take_scrolled), which
    // is what keeps the arithmetic true.
    //
    //   scrollback[i]   -> m_firstLineId + i
    //   screen row s    -> m_firstLineId + scrollbackLines() + s
    //
    // and both reduce to the same expression in terms of a view row,
    // which is why there is only one of these.
    qint64 lineIdFor(int viewRow) const {
        return m_firstLineId + scrollbackLines() + viewRow - m_scrollOffset;
    }
    int viewRowFor(qint64 id) const {
        return static_cast<int>(id - m_firstLineId - scrollbackLines() + m_scrollOffset);
    }
    qint64 firstLineId() const { return m_firstLineId; }
    qint64 lastLineId() const { return m_firstLineId + scrollbackLines() + m_rows - 1; }

    Q_INVOKABLE QString textOfLines(qint64 id0, int col0, qint64 id1, int col1) const;
    int scrollOffset() const { return m_scrollOffset; }
    void setScrollOffset(int off);
    bool cursorVisible() const { return m_cursorVisible; }
    // What to draw, which is not always what the program asked for.
    //
    // DECSCUSR — ESC [ n SP q — lets a program pick the cursor's shape,
    // and fish sends one on every prompt: CachyOS's config asks for a
    // block. So the caret turned back into a block the moment a real
    // shell was underneath it, on a machine where the default had never
    // been touched.
    //
    // At a shell prompt the shape carries no information — it is just a
    // house style, and the house style here is a caret. Inside a
    // full-screen program it carries a great deal: vim says which mode
    // you are in with it, and overriding that would be taking something
    // away. The alternate screen is exactly that line, so the program is
    // obeyed there and nowhere else.
    //
    // HYPRSHELL_TERM_APP_CURSOR=1 obeys it everywhere, for anyone who
    // wants their shell to decide.
    int cursorShape() const {
        static const bool obey = qEnvironmentVariableIsSet("HYPRSHELL_TERM_APP_CURSOR");
        if (obey || m_altScreen) return m_appCursorShape;
        return 3;   // a bar
    }
    bool cursorBlink() const { return m_cursorBlink; }
    int cursorRow() const { return m_st.cursor_row; }
    int cursorCol() const { return m_st.cursor_col; }
    bool running() const;
    bool mouseEnabled() const { return m_mouse != 0; }
    bool altScreen() const { return m_altScreen; }

    // For the view. `row` is in view coordinates: 0 is the top visible
    // line, which is a scrollback line when the view is scrolled up.
    bool cellAt(int row, int col, HtCell *out) const;
    // A cell's colours, with the theme's own resolved now rather than
    // when the cell was written, so a theme change repaints everything.
    QColor fgOf(const HtCell &c) const {
        return c.fg_default ? m_defaultFg : QColor::fromRgb(c.fg);
    }
    QColor bgOf(const HtCell &c) const {
        return c.bg_default ? m_defaultBg : QColor::fromRgb(c.bg);
    }
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
    void cursorStyleChanged();
    void runningChanged();
    void mouseEnabledChanged();
    void altScreenChanged();
    void bell();
    void exited(int code);

private:
    static void onCore(void *user, int32_t kind, const uint8_t *data, size_t len);

    void feed(const QByteArray &data);
    // After anything that may have changed the screen: read the core's
    // state and say what changed.
    void refresh();
    void markDamaged();

    HtCore *m_core = nullptr;
    HtState m_st {};
    Pty *m_pty = nullptr;

    int m_rows = 24;
    int m_cols = 80;
    int m_cellW = 0;
    int m_cellH = 0;
    QString m_title;
    QString m_cwd;

    int m_scrollOffset = 0;
    // The id of scrollback[0]; see lineIdFor(). Grows when the oldest
    // lines are dropped, so ids never repeat and never shift.
    qint64 m_firstLineId = 0;

    int m_mouse = 0;
    bool m_altScreen = false;

    bool m_cursorVisible = true;
    int m_appCursorShape = 3;       // what the program last asked for
    bool m_cursorBlink = true;

    // A synchronized update (mode 2026) the program has not finished is
    // shown anyway after a moment.
    QTimer m_sync;

    QColor m_defaultFg { "#e8e6e3" };
    QColor m_defaultBg { "#1a1a18" };

    // Repaints are coalesced: a program writing a screenful sends dozens
    // of damage rectangles for one visible change, and painting each
    // would spend the frame on work nobody sees.
    QTimer m_repaint;
};

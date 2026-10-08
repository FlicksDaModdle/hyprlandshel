#include "term.h"
#include "ptyproc.h"

#include <QClipboard>
#include <QGuiApplication>

// Qt's key codes, kept out of the header so this file is the only place
// that knows about both halves.
#include <QtGui/qevent.h>

Term::Term(QObject *parent) : QObject(parent) {
    m_core = ht_new(m_rows, m_cols);
    ht_set_callback(m_core, &Term::onCore, this);
    ht_state(m_core, &m_st);

    m_repaint.setSingleShot(true);
    m_repaint.setInterval(8);   // about a frame
    connect(&m_repaint, &QTimer::timeout, this, &Term::damaged);

    m_sync.setSingleShot(true);
    connect(&m_sync, &QTimer::timeout, this, [this] {
        ht_sync_flush(m_core);
        refresh();
        markDamaged();
    });
}

Term::~Term() {
    // The pty first: its last output must not arrive at a core that is
    // gone.
    delete m_pty;
    m_pty = nullptr;
    if (m_core) ht_free(m_core);
}

void Term::setPalette(const QColor &fg, const QColor &bg, const QStringList &ansi16) {
    m_defaultFg = fg;
    m_defaultBg = bg;
    uint32_t pal[16];
    // Anything not given keeps a sensible colour rather than black.
    static const uint32_t fallback[16] = {
        0x1a1a18, 0xd9534f, 0x5cb85c, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xdcdcdc,
        0x5c6370, 0xe06c75, 0x98c379, 0xf0d58c, 0x7cbcf5, 0xd7a0e8, 0x7fd0db, 0xffffff,
    };
    for (int i = 0; i < 16; ++i) {
        const QColor c = i < ansi16.size() ? QColor(ansi16.at(i)) : QColor();
        pal[i] = c.isValid() ? (c.rgb() & 0xffffff) : fallback[i];
    }
    ht_set_palette(m_core, fg.rgb() & 0xffffff, bg.rgb() & 0xffffff, pal);
    markDamaged();
}

void Term::start(const QStringList &argv) {
    if (m_pty) return;
    m_pty = new Pty(this);
    connect(m_pty, &Pty::output, this, &Term::feed);
    connect(m_pty, &Pty::finished, this, [this](int code) {
        emit runningChanged();
        emit exited(code);
    });
    m_pty->start(argv, m_rows, m_cols);
    emit runningChanged();
}

bool Term::running() const { return m_pty && m_pty->running(); }

void Term::feed(const QByteArray &data) {
    ht_feed(m_core, reinterpret_cast<const uint8_t *>(data.constData()),
            static_cast<size_t>(data.size()));
    const qint64 wait = ht_sync_wait(m_core);
    if (wait >= 0) m_sync.start(static_cast<int>(wait) + 1);
    // Anything arriving means the live screen is what should be shown:
    // watching output scroll past while looking at history is a terminal
    // fighting you.
    if (m_scrollOffset != 0) { m_scrollOffset = 0; emit scrollOffsetChanged(); }
    refresh();
    markDamaged();
}

void Term::refresh() {
    const HtState was = m_st;
    ht_state(m_core, &m_st);

    // Line ids: the line at the bottom keeps its id however far it went
    // up — see lineIdFor().
    const qint64 scrolled = ht_take_scrolled(m_core);
    m_firstLineId += was.history - m_st.history + scrolled;

    if (m_st.rows != was.rows || m_st.cols != was.cols) {
        m_rows = m_st.rows;
        m_cols = m_st.cols;
        emit sizeChanged();
    }
    if (m_st.history != was.history || scrolled != 0) emit scrollbackChanged();
    if (m_st.cursor_row != was.cursor_row || m_st.cursor_col != was.cursor_col
        || m_st.cursor_visible != was.cursor_visible) {
        m_cursorVisible = m_st.cursor_visible != 0;
        emit cursorChanged();
    }
    if (m_st.mouse != was.mouse) {
        m_mouse = m_st.mouse;
        emit mouseEnabledChanged();
    }
    const bool styleChanged = m_st.cursor_shape != was.cursor_shape
                           || m_st.cursor_blink != was.cursor_blink
                           || m_st.alt_screen != was.alt_screen;
    m_appCursorShape = m_st.cursor_shape;
    m_cursorBlink = m_st.cursor_blink != 0;
    if (m_st.alt_screen != was.alt_screen) {
        // Nothing scrolls back out of the alternate screen, and a view
        // still scrolled up when `less` starts would be showing history
        // that the program does not know is there.
        m_altScreen = m_st.alt_screen != 0;
        emit altScreenChanged();
        setScrollOffset(0);
    }
    // Leaving or entering the alternate screen changes which shape is
    // drawn — see cursorShape().
    if (styleChanged) emit cursorStyleChanged();
    if (m_scrollOffset > m_st.history) setScrollOffset(m_st.history);
}

void Term::markDamaged() {
    if (!m_repaint.isActive()) m_repaint.start();
}

void Term::setSize(int rows, int cols) {
    if (rows <= 0 || cols <= 0) return;
    if (rows == m_rows && cols == m_cols) return;
    ht_resize(m_core, rows, cols, m_cellW, m_cellH);
    if (m_pty) m_pty->resize(rows, cols);
    refresh();
    markDamaged();
}

void Term::setScrollOffset(int off) {
    const int max = m_st.history;
    const int clamped = qBound(0, off, max);
    if (clamped == m_scrollOffset) return;
    m_scrollOffset = clamped;
    emit scrollOffsetChanged();
    markDamaged();
}

static int32_t htMods(int mods) {
    int32_t m = 0;
    if (mods & Qt::ShiftModifier)   m |= HT_MOD_SHIFT;
    if (mods & Qt::AltModifier)     m |= HT_MOD_ALT;
    if (mods & Qt::ControlModifier) m |= HT_MOD_CTRL;
    return m;
}

void Term::sendMouse(int row, int col, int button, bool pressed, int mods) {
    if (!m_pty) return;
    ht_mouse(m_core, row, col, button, pressed, htMods(mods));
}

// Clicking into the line being edited.
//
// The shell owns that line; the terminal only forwards keys. So a click
// is turned into the keys that would have got the cursor there — as many
// lefts or rights as the distance, counted through the wrap, because a
// long command line is one line however many rows it occupies.
//
// Refused rather than guessed at in three cases: in the alternate screen
// arrows mean whatever the full-screen program says they mean and are
// certainly not cursor movement; while scrolled up the rows on screen
// are not the rows the shell is editing; and beyond a few lines' worth of
// distance a click is far more likely to be aimed at old output than at
// the prompt, where a thousand arrow keys would be a mess to undo.
void Term::placeCursor(int row, int col) {
    if (!m_pty || m_altScreen || m_scrollOffset != 0) return;
    if (m_cols <= 0) return;

    const int delta = (row - m_st.cursor_row) * m_cols + (col - m_st.cursor_col);
    if (delta == 0) return;
    if (qAbs(delta) > m_cols * 6) return;

    QByteArray keys;
    const char *arrow = delta > 0 ? "\x1b[C" : "\x1b[D";
    keys.reserve(qAbs(delta) * 3);
    for (int i = 0; i < qAbs(delta); ++i) keys.append(arrow, 3);
    m_pty->write(keys);
    scrollToBottom();
}

// The line editor (readline, zle, fish) knows nothing of the screen, only
// of the line it holds and where its cursor is in it, so a selection is
// deleted through the keys a person would press: arrows to its end, one
// backspace per character. That holds only where those keys reach — the
// input line — so the selection has to sit on the cursor's own line, or on
// rows it wraps across, at a prompt rather than in a full-screen program.
// The prompt itself cannot be told from what was typed; a selection that
// takes some of it in deletes back to where the input starts, and the
// editor refuses the rest.
bool Term::eraseSelection(qint64 id0, int col0, qint64 id1, int col1) {
    if (!m_pty || m_altScreen || m_mouse || m_cols <= 0) return false;
    if (id1 < id0 || (id1 == id0 && col1 < col0)) { std::swap(id0, id1); std::swap(col0, col1); }

    // Lines of the live screen, 0 at its top.
    const qint64 base = m_firstLineId + scrollbackLines();
    const int l0 = static_cast<int>(id0 - base), l1 = static_cast<int>(id1 - base);
    const int cur = m_st.cursor_row;
    if (l0 < 0 || l1 >= m_rows) return false;
    const int lo = qMin(l0, cur), hi = qMax(l1, cur);
    if (hi - lo > 6) return false;

    auto cellOf = [&](int line, int col, HtCell *c) { return ht_cell(m_core, line, col, c); };
    // One logical line: every row but the last full to its edge, which is
    // what a line wrapping onto the next looks like. A row that stops short
    // ends a line, and the editor's arrows do not cross into another.
    for (int r = lo; r < hi; ++r) {
        HtCell c;
        if (!cellOf(r, m_cols - 1, &c) || c.chars[0] == 0) return false;
    }

    const int P = cur * m_cols + m_st.cursor_col;
    // Where the typing ends: its last character, or the cursor if that is
    // past it (spaces typed at the end). Selected blank space beyond it is
    // not in the line, and is not deleted.
    int inputEnd = P;
    for (int r = lo; r <= hi; ++r)
        for (int c = 0; c < m_cols; ++c) {
            HtCell cell;
            if (cellOf(r, c, &cell) && cell.chars[0] != 0 && cell.chars[0] != ' ')
                inputEnd = qMax(inputEnd, r * m_cols + c + 1);
        }
    const int S = l0 * m_cols + col0;
    const int E = qMin(l1 * m_cols + col1 + 1, inputEnd);
    if (E <= S) return true;    // nothing of the line in it: done

    // Characters, not cells: the second half of a wide character is not
    // a keystroke of its own.
    auto chars = [&](int from, int to) {
        int n = 0;
        for (int k = from; k < to; ++k) {
            HtCell cell;
            if (!cellOf(k / m_cols, k % m_cols, &cell) || cell.width != 0) ++n;
        }
        return n;
    };
    // Through sendKey, so the arrows are spelled as the editor asked for
    // them (application cursor mode or not) and backspace as it expects.
    if (E > P) for (int i = chars(P, E); i > 0; --i) sendKey(Qt::Key_Right, 0, QString());
    else for (int i = chars(E, P); i > 0; --i) sendKey(Qt::Key_Left, 0, QString());
    for (int i = chars(S, E); i > 0; --i) sendKey(Qt::Key_Backspace, 0, QString());
    scrollToBottom();
    return true;
}

void Term::scrollBy(int lines) { setScrollOffset(m_scrollOffset + lines); }
void Term::scrollToBottom() { setScrollOffset(0); }

// ── what the view reads ──────────────────────────────────────────────────
bool Term::cellAt(int row, int col, HtCell *out) const {
    if (col < 0 || col >= m_cols) return false;
    // Above the live screen by however far the view is scrolled up; the
    // core numbers scrollback upwards from -1.
    const int line = row - m_scrollOffset;
    if (line >= m_rows || line < -m_st.history) return false;
    return ht_cell(m_core, line, col, out);
}

// The same as textOfRange, addressed by line id rather than by where a
// line happens to be sitting in the view.
QString Term::textOfLines(qint64 id0, int col0, qint64 id1, int col1) const {
    if (id1 < id0 || (id1 == id0 && col1 < col0)) {
        std::swap(id0, id1);
        std::swap(col0, col1);
    }
    return textOfRange(viewRowFor(id0), col0, viewRowFor(id1), col1);
}

QString Term::textOfRange(int row0, int col0, int row1, int col1) const {
    if (row1 < row0 || (row1 == row0 && col1 < col0)) {
        std::swap(row0, row1);
        std::swap(col0, col1);
    }
    QString out;
    for (int r = row0; r <= row1; ++r) {
        const int from = (r == row0) ? col0 : 0;
        const int to = (r == row1) ? col1 : m_cols - 1;
        QString line;
        for (int c = from; c <= to && c < m_cols; ++c) {
            HtCell cell;
            if (!cellAt(r, c, &cell)) continue;
            if (cell.width == 0) continue;
            if (cell.chars[0] == 0) { line.append(QChar(' ')); continue; }
            for (int i = 0; i < HT_MAX_CHARS && cell.chars[i]; ++i)
                line.append(QChar::fromUcs4(cell.chars[i]));
        }
        // Trailing blanks are padding, not content: a copied line should
        // not carry the rest of the terminal's width with it.
        while (line.endsWith(QChar(' '))) line.chop(1);
        out += line;
        if (r != row1) out += QChar('\n');
    }
    return out;
}

// ── what the core says ───────────────────────────────────────────────────
void Term::onCore(void *user, int32_t kind, const uint8_t *data, size_t len) {
    Term *t = static_cast<Term *>(user);
    const QByteArray bytes(reinterpret_cast<const char *>(data), static_cast<int>(len));
    switch (kind) {
    case HT_EV_WRITE:
        // Answers to the program's questions, and the keys and clicks
        // encoded for it.
        if (t->m_pty) t->m_pty->write(bytes);
        break;
    case HT_EV_TITLE: {
        const QString title = QString::fromUtf8(bytes);
        if (title != t->m_title) { t->m_title = title; emit t->titleChanged(); }
        break;
    }
    case HT_EV_BELL:
        emit t->bell();
        break;
    case HT_EV_CWD: {
        const QString path = QString::fromUtf8(bytes);
        if (!path.isEmpty() && path != t->m_cwd) { t->m_cwd = path; emit t->cwdChanged(); }
        break;
    }
    case HT_EV_CLIPBOARD:
        // OSC 52: a program copying, the way vim and tmux do over ssh.
        // Copy only; nothing on the far side may read the clipboard.
        QGuiApplication::clipboard()->setText(QString::fromUtf8(bytes));
        break;
    default:
        break;
    }
}

// ── input ────────────────────────────────────────────────────────────────
void Term::sendText(const QString &text) {
    if (!m_pty) return;
    m_pty->write(text.toUtf8());
    scrollToBottom();
}

void Term::paste(const QString &text) {
    if (!m_pty || text.isEmpty()) return;
    const QByteArray b = text.toUtf8();
    ht_paste(m_core, reinterpret_cast<const uint8_t *>(b.constData()), static_cast<size_t>(b.size()));
    scrollToBottom();
}

void Term::setFocused(bool focused) {
    if (m_pty) ht_focus(m_core, focused);
}

void Term::sendKey(int key, int mods, const QString &text) {
    if (!m_pty) return;

    // ── the word-wise editing keys ────────────────────────────────────
    //
    // These are the ones people expect to behave the way they do in a text
    // box: ctrl and an arrow moves a word, ctrl and a delete key removes
    // one. The arrows are fine as xterm sends them — CSI 1;5D and its
    // friends are what every shell already binds — but the delete keys are
    // not: ctrl-backspace has no sequence shells agree on (libvterm sent
    // the kitty protocol's CSI 127;5u, which readline, fish and zsh bind
    // none of), and the key looked swallowed.
    //
    // So those two are sent as the sequences shells have bound for
    // decades.
    if (mods & Qt::ControlModifier) {
        if (key == Qt::Key_Backspace) {
            // Alt-backspace: backward-kill-word. Bound in bash, zsh and
            // fish, and stops at punctuation the way a text box does —
            // unlike ^W, which runs to the previous space.
            m_pty->write(QByteArrayLiteral("\x1b\x7f"));
            scrollToBottom();
            return;
        }
        if (key == Qt::Key_Delete) {
            // Alt-d: kill-word, the same thing forwards.
            //
            // Split across two literals on purpose: "\x1bd" is one hex
            // escape, not ESC followed by 'd' — the compiler reads as many
            // hex digits as it can and hands back a single truncated byte.
            // It sent 0xbd, which is not a key anything has ever bound.
            m_pty->write(QByteArrayLiteral("\x1b" "d"));
            scrollToBottom();
            return;
        }
    }

    int32_t hkey = 0;
    switch (key) {
    case Qt::Key_Return:
    case Qt::Key_Enter:     hkey = HT_KEY_ENTER; break;
    case Qt::Key_Tab:       hkey = HT_KEY_TAB; break;
    case Qt::Key_Backtab:   hkey = HT_KEY_BACKTAB; break;
    case Qt::Key_Backspace: hkey = HT_KEY_BACKSPACE; break;
    case Qt::Key_Escape:    hkey = HT_KEY_ESCAPE; break;
    case Qt::Key_Up:        hkey = HT_KEY_UP; break;
    case Qt::Key_Down:      hkey = HT_KEY_DOWN; break;
    case Qt::Key_Left:      hkey = HT_KEY_LEFT; break;
    case Qt::Key_Right:     hkey = HT_KEY_RIGHT; break;
    case Qt::Key_Insert:    hkey = HT_KEY_INSERT; break;
    case Qt::Key_Delete:    hkey = HT_KEY_DELETE; break;
    case Qt::Key_Home:      hkey = HT_KEY_HOME; break;
    case Qt::Key_End:       hkey = HT_KEY_END; break;
    case Qt::Key_PageUp:    hkey = HT_KEY_PAGE_UP; break;
    case Qt::Key_PageDown:  hkey = HT_KEY_PAGE_DOWN; break;
    default: break;
    }
    if (key >= Qt::Key_F1 && key <= Qt::Key_F20)
        hkey = HT_KEY_F0 + 1 + (key - Qt::Key_F1);

    if (hkey != 0) {
        ht_key(m_core, hkey, htMods(mods), nullptr, 0);
        scrollToBottom();
        return;
    }

    // Control combinations are the character with the modifier, not the
    // control code Qt already made of it: the core makes the code, the
    // same way for every layout. Sending the text as well would type a
    // stray letter alongside every ^C.
    QString t = text;
    if ((mods & Qt::ControlModifier) && key >= 0x20 && key < 0x7f)
        t = QString(QChar(key).toLower());
    if (t.isEmpty()) return;
    const QByteArray b = t.toUtf8();
    // Shift has already made the text what it is.
    ht_key(m_core, 0, htMods(mods) & ~HT_MOD_SHIFT,
           reinterpret_cast<const uint8_t *>(b.constData()), static_cast<size_t>(b.size()));
    scrollToBottom();
}

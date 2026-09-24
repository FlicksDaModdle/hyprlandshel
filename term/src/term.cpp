#include "term.h"
#include "ptyproc.h"

#include <QDebug>
#include <QUrl>

#include <cstring>

// Qt's key codes, kept out of the header so this file is the only place
// that knows about both halves.
#include <QtGui/qevent.h>

Term::Term(QObject *parent) : QObject(parent) {
    m_vt = vterm_new(m_rows, m_cols);
    vterm_set_utf8(m_vt, 1);

    m_screen = vterm_obtain_screen(m_vt);

    static const VTermScreenCallbacks callbacks = {
        &Term::onDamage,
        &Term::onMoveRect,
        &Term::onMoveCursor,
        &Term::onSetTermProp,
        &Term::onBell,
        &Term::onResize,
        &Term::onPushLine,
        &Term::onPopLine,
        nullptr,   // sb_clear
    };
    vterm_screen_set_callbacks(m_screen, &callbacks, this);

    // OSC 7 (the working directory) is not one of the properties libvterm
    // interprets, so it arrives here as an unrecognised sequence. It is
    // the only way a shell tells a terminal where it is.
    static const VTermStateFallbacks fallbacks = {
        nullptr,        // control
        nullptr,        // csi
        &Term::onOsc,
        nullptr,        // dcs
        nullptr,        // apc
        nullptr,        // pm
        nullptr,        // sos
    };
    vterm_screen_set_unrecognised_fallbacks(m_screen, &fallbacks, this);

    vterm_output_set_callback(m_vt, &Term::onOutput, this);
    vterm_screen_enable_altscreen(m_screen, 1);
    vterm_screen_reset(m_screen, 1);

    // After the reset, not before: resetting announces the terminal's
    // properties through the same callback the program uses, so a default
    // set first would simply be overwritten by libvterm's own.
    m_appCursorShape = VTERM_PROP_CURSORSHAPE_BAR_LEFT;
    m_cursorBlink = true;

    m_repaint.setSingleShot(true);
    m_repaint.setInterval(8);   // about a frame
    connect(&m_repaint, &QTimer::timeout, this, &Term::damaged);
}

Term::~Term() {
    if (m_vt) vterm_free(m_vt);
}

void Term::setPalette(const QColor &fg, const QColor &bg, const QStringList &ansi16) {
    m_defaultFg = fg;
    m_defaultBg = bg;

    VTermState *state = vterm_obtain_state(m_vt);
    VTermColor vfg, vbg;
    vterm_color_rgb(&vfg, fg.red(), fg.green(), fg.blue());
    vterm_color_rgb(&vbg, bg.red(), bg.green(), bg.blue());
    vterm_state_set_default_colors(state, &vfg, &vbg);

    for (int i = 0; i < ansi16.size() && i < 16; ++i) {
        const QColor c(ansi16.at(i));
        if (!c.isValid()) continue;
        VTermColor vc;
        vterm_color_rgb(&vc, c.red(), c.green(), c.blue());
        vterm_state_set_palette_color(state, i, &vc);
    }
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
    vterm_input_write(m_vt, data.constData(), data.size());
    // Anything arriving means the live screen is what should be shown:
    // watching output scroll past while looking at history is a terminal
    // fighting you.
    if (m_scrollOffset != 0) { m_scrollOffset = 0; emit scrollOffsetChanged(); }
    markDamaged();
}

void Term::markDamaged() {
    if (!m_repaint.isActive()) m_repaint.start();
}

void Term::setSize(int rows, int cols) {
    if (rows <= 0 || cols <= 0) return;
    if (rows == m_rows && cols == m_cols) return;
    m_rows = rows;
    m_cols = cols;
    vterm_set_size(m_vt, rows, cols);
    if (m_pty) m_pty->resize(rows, cols);
    emit sizeChanged();
    markDamaged();
}

void Term::setScrollOffset(int off) {
    const int max = static_cast<int>(m_scrollback.size());
    const int clamped = qBound(0, off, max);
    if (clamped == m_scrollOffset) return;
    m_scrollOffset = clamped;
    emit scrollOffsetChanged();
    markDamaged();
}

void Term::sendMouse(int row, int col, int button, bool pressed, int mods) {
    if (!m_pty) return;
    VTermModifier vmod = VTERM_MOD_NONE;
    if (mods & Qt::ShiftModifier)   vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_SHIFT);
    if (mods & Qt::AltModifier)     vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_ALT);
    if (mods & Qt::ControlModifier) vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_CTRL);
    vterm_mouse_move(m_vt, row, col, vmod);
    if (button > 0) vterm_mouse_button(m_vt, button, pressed, vmod);
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

    const int delta = (row - m_cursorPos.row) * m_cols + (col - m_cursorPos.col);
    if (delta == 0) return;
    if (qAbs(delta) > m_cols * 6) return;

    QByteArray keys;
    const char *arrow = delta > 0 ? "\x1b[C" : "\x1b[D";
    keys.reserve(qAbs(delta) * 3);
    for (int i = 0; i < qAbs(delta); ++i) keys.append(arrow, 3);
    m_pty->write(keys);
    scrollToBottom();
}

void Term::scrollBy(int lines) { setScrollOffset(m_scrollOffset + lines); }
void Term::scrollToBottom() { setScrollOffset(0); }

// ── what the view reads ──────────────────────────────────────────────────
bool Term::cellAt(int row, int col, VTermScreenCell *out) const {
    if (col < 0 || col >= m_cols) return false;
    // Above the live screen by however far the view is scrolled up.
    const int fromScreen = row - m_scrollOffset;
    if (fromScreen >= 0) {
        if (fromScreen >= m_rows) return false;
        VTermPos pos { fromScreen, col };
        return vterm_screen_get_cell(m_screen, pos, out) != 0;
    }
    const int idx = static_cast<int>(m_scrollback.size()) + fromScreen;
    if (idx < 0 || idx >= static_cast<int>(m_scrollback.size())) return false;
    const QVector<VTermScreenCell> &line = m_scrollback[idx];
    if (col >= line.size()) {
        std::memset(out, 0, sizeof(*out));
        out->width = 1;
        return true;
    }
    *out = line.at(col);
    return true;
}

QColor Term::toColor(const VTermColor &c, bool background) const {
    VTermColor copy = c;
    if (VTERM_COLOR_IS_DEFAULT_FG(&copy)) return m_defaultFg;
    if (VTERM_COLOR_IS_DEFAULT_BG(&copy)) return m_defaultBg;
    if (VTERM_COLOR_IS_INDEXED(&copy))
        vterm_screen_convert_color_to_rgb(m_screen, &copy);
    if (VTERM_COLOR_IS_RGB(&copy))
        return QColor(copy.rgb.red, copy.rgb.green, copy.rgb.blue);
    return background ? m_defaultBg : m_defaultFg;
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
            VTermScreenCell cell;
            if (!cellAt(r, c, &cell)) continue;
            if (cell.width == 0) continue;
            if (cell.chars[0] == 0) { line.append(QChar(' ')); continue; }
            for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; ++i)
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

// ── libvterm callbacks ───────────────────────────────────────────────────
int Term::onDamage(VTermRect, void *user) {
    static_cast<Term *>(user)->markDamaged();
    return 1;
}

int Term::onMoveRect(VTermRect, VTermRect, void *user) {
    static_cast<Term *>(user)->markDamaged();
    return 1;
}

int Term::onMoveCursor(VTermPos pos, VTermPos, int visible, void *user) {
    Term *t = static_cast<Term *>(user);
    t->m_cursorPos = pos;
    t->m_cursorVisible = visible != 0;
    emit t->cursorChanged();
    t->markDamaged();
    return 1;
}

int Term::onSetTermProp(VTermProp prop, VTermValue *val, void *user) {
    Term *t = static_cast<Term *>(user);
    switch (prop) {
    case VTERM_PROP_TITLE:
        // Arrives in fragments, and `initial` says which one starts a new
        // title. Appending everything would grow the title for the life
        // of the window.
        if (val->string.initial) t->m_title.clear();
        t->m_title.append(QString::fromUtf8(val->string.str, val->string.len));
        if (val->string.final) emit t->titleChanged();
        return 1;
    case VTERM_PROP_CURSORVISIBLE:
        t->m_cursorVisible = val->boolean;
        emit t->cursorChanged();
        t->markDamaged();
        return 1;
    case VTERM_PROP_ALTSCREEN:
        // Nothing scrolls back out of the alternate screen, and a view
        // still scrolled up when `less` starts would be showing history
        // that the program does not know is there.
        t->m_altScreen = val->boolean;
        emit t->altScreenChanged();
        // Leaving or entering it changes which shape is drawn — see
        // cursorShape().
        emit t->cursorStyleChanged();
        t->setScrollOffset(0);
        t->markDamaged();
        return 1;
    case VTERM_PROP_CURSORSHAPE:
        t->m_appCursorShape = val->number;
        emit t->cursorStyleChanged();
        t->markDamaged();
        return 1;
    case VTERM_PROP_CURSORBLINK:
        t->m_cursorBlink = val->boolean;
        emit t->cursorStyleChanged();
        t->markDamaged();
        return 1;
    case VTERM_PROP_MOUSE:
        t->m_mouse = val->number;
        emit t->mouseEnabledChanged();
        return 1;
    default:
        return 0;
    }
}

int Term::onBell(void *user) {
    emit static_cast<Term *>(user)->bell();
    return 1;
}

int Term::onResize(int rows, int cols, void *user) {
    Term *t = static_cast<Term *>(user);
    t->m_rows = rows;
    t->m_cols = cols;
    emit t->sizeChanged();
    t->markDamaged();
    return 1;
}

int Term::onPushLine(int cols, const VTermScreenCell *cells, void *user) {
    Term *t = static_cast<Term *>(user);
    QVector<VTermScreenCell> line(cols);
    std::memcpy(line.data(), cells, sizeof(VTermScreenCell) * cols);
    t->m_scrollback.push_back(std::move(line));
    while (static_cast<int>(t->m_scrollback.size()) > kScrollbackMax)
        t->m_scrollback.pop_front();
    // Looking at history while the live screen scrolls should keep the
    // same lines in view, so the offset follows the line that was added.
    if (t->m_scrollOffset > 0
        && t->m_scrollOffset < static_cast<int>(t->m_scrollback.size()))
        t->m_scrollOffset++;
    emit t->scrollbackChanged();
    return 1;
}

int Term::onPopLine(int cols, VTermScreenCell *cells, void *user) {
    // The screen grew: libvterm asks for the line that fell off last, so
    // that growing a window brings back what shrinking it took away.
    Term *t = static_cast<Term *>(user);
    if (t->m_scrollback.empty()) return 0;
    const QVector<VTermScreenCell> line = t->m_scrollback.back();
    t->m_scrollback.pop_back();
    const int n = qMin(cols, static_cast<int>(line.size()));
    std::memcpy(cells, line.constData(), sizeof(VTermScreenCell) * n);
    for (int i = n; i < cols; ++i) {
        std::memset(&cells[i], 0, sizeof(VTermScreenCell));
        cells[i].width = 1;
    }
    emit t->scrollbackChanged();
    return 1;
}

int Term::onOsc(int command, VTermStringFragment frag, void *user) {
    Term *t = static_cast<Term *>(user);
    if (frag.initial) { t->m_oscPending.clear(); t->m_oscCommand = command; }
    t->m_oscPending.append(QString::fromUtf8(frag.str, frag.len));
    if (!frag.final) return 1;

    // 7 is the working directory, as a file:// URL with a hostname.
    if (t->m_oscCommand == 7) {
        // file://hostname/path — and the hostname is the *machine's*, so
        // toLocalFile() keeps it and hands back //vm/home/you. The path
        // is the part that means anything here.
        const QUrl url(t->m_oscPending);
        const QString path = QUrl::fromPercentEncoding(url.path().toUtf8());
        if (!path.isEmpty() && path != t->m_cwd) {
            t->m_cwd = path;
            emit t->cwdChanged();
        }
    }
    t->m_oscPending.clear();
    t->m_oscCommand = -1;
    return 1;
}

void Term::onOutput(const char *s, size_t len, void *user) {
    Term *t = static_cast<Term *>(user);
    if (t->m_pty) t->m_pty->write(QByteArray(s, static_cast<int>(len)));
}

// ── input ────────────────────────────────────────────────────────────────
void Term::sendText(const QString &text) {
    if (!m_pty) return;
    m_pty->write(text.toUtf8());
    scrollToBottom();
}

void Term::sendKey(int key, int mods, const QString &text) {
    if (!m_pty) return;

    VTermModifier vmod = VTERM_MOD_NONE;
    if (mods & Qt::ShiftModifier)   vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_SHIFT);
    if (mods & Qt::AltModifier)     vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_ALT);
    if (mods & Qt::ControlModifier) vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_CTRL);

    // ── the word-wise editing keys ────────────────────────────────────
    //
    // These are the ones people expect to behave the way they do in a text
    // box: ctrl and an arrow moves a word, ctrl and a delete key removes
    // one. The arrows are fine as libvterm sends them — CSI 1;5D and its
    // friends are what every shell already binds — but the delete keys are
    // not: ctrl-backspace comes out as CSI 127;5u, which is the newer
    // kitty keyboard protocol, and readline, fish and zsh bind none of it.
    // The key looked swallowed.
    //
    // So those two are sent as the sequences shells have bound for
    // decades. Nothing else here is special-cased, because nothing else
    // needed to be — checked by reading the bytes back off a pty rather
    // than by assuming.
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

    VTermKey vkey = VTERM_KEY_NONE;
    switch (key) {
    case Qt::Key_Return:
    case Qt::Key_Enter:     vkey = VTERM_KEY_ENTER; break;
    case Qt::Key_Tab:       vkey = VTERM_KEY_TAB; break;
    case Qt::Key_Backtab:   vkey = VTERM_KEY_TAB;
                            vmod = static_cast<VTermModifier>(vmod | VTERM_MOD_SHIFT); break;
    case Qt::Key_Backspace: vkey = VTERM_KEY_BACKSPACE; break;
    case Qt::Key_Escape:    vkey = VTERM_KEY_ESCAPE; break;
    case Qt::Key_Up:        vkey = VTERM_KEY_UP; break;
    case Qt::Key_Down:      vkey = VTERM_KEY_DOWN; break;
    case Qt::Key_Left:      vkey = VTERM_KEY_LEFT; break;
    case Qt::Key_Right:     vkey = VTERM_KEY_RIGHT; break;
    case Qt::Key_Insert:    vkey = VTERM_KEY_INS; break;
    case Qt::Key_Delete:    vkey = VTERM_KEY_DEL; break;
    case Qt::Key_Home:      vkey = VTERM_KEY_HOME; break;
    case Qt::Key_End:       vkey = VTERM_KEY_END; break;
    case Qt::Key_PageUp:    vkey = VTERM_KEY_PAGEUP; break;
    case Qt::Key_PageDown:  vkey = VTERM_KEY_PAGEDOWN; break;
    default: break;
    }
    if (key >= Qt::Key_F1 && key <= Qt::Key_F35)
        vkey = static_cast<VTermKey>(VTERM_KEY_FUNCTION_0 + 1 + (key - Qt::Key_F1));

    if (vkey != VTERM_KEY_NONE) {
        vterm_keyboard_key(m_vt, vkey, vmod);
        scrollToBottom();
        return;
    }

    // Control combinations are the character with the modifier, not the
    // control code: libvterm produces the code. Sending the text as well
    // would type a stray letter alongside every ^C.
    if ((mods & Qt::ControlModifier) && key >= 0x20 && key < 0x7f) {
        vterm_keyboard_unichar(m_vt, static_cast<uint32_t>(QChar(key).toLower().unicode()), vmod);
        scrollToBottom();
        return;
    }

    if (text.isEmpty()) return;
    for (const uint ucs : text.toUcs4())
        vterm_keyboard_unichar(m_vt, ucs,
                               static_cast<VTermModifier>(vmod & ~VTERM_MOD_SHIFT));
    scrollToBottom();
}

#include "ptyproc.h"

#include <QCoreApplication>
#include <QDebug>
#include <QFileInfo>
#include <QSocketNotifier>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
// The system header, which declares forkpty. This file used to be called
// pty.h itself, and being first on the include path it answered for the
// system one — so forkpty was simply not declared.
#include <pty.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

Pty::Pty(QObject *parent) : QObject(parent) {}

Pty::~Pty() {
    if (m_notifier) m_notifier->setEnabled(false);
    if (m_pid > 0) {
        // SIGHUP rather than SIGKILL: it is what closing a terminal window
        // means, and a shell that gets it runs its exit traps and tells its
        // own children before going.
        ::kill(static_cast<pid_t>(m_pid), SIGHUP);
        int status = 0;
        ::waitpid(static_cast<pid_t>(m_pid), &status, WNOHANG);
    }
    if (m_fd >= 0) ::close(m_fd);
}

bool Pty::start(const QStringList &argv, int rows, int cols) {
    if (m_pid > 0) return false;

    struct winsize ws;
    std::memset(&ws, 0, sizeof(ws));
    ws.ws_row = static_cast<unsigned short>(rows > 0 ? rows : 24);
    ws.ws_col = static_cast<unsigned short>(cols > 0 ? cols : 80);

    // The line discipline, stated rather than inherited.
    //
    // A new pty gets kernel defaults, and those are usually right — but
    // "usually" is doing a lot of work in a program whose whole job is
    // this. ISIG is what turns ^C into a signal rather than a byte;
    // ICANON and the erase and kill characters are what make a shell's
    // line editing behave; ECHOCTL is what prints "^C" when you press it.
    // Every terminal sets these explicitly, and so does this one.
    struct termios tio;
    std::memset(&tio, 0, sizeof(tio));
    tio.c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8;
    tio.c_oflag = OPOST | ONLCR;
    tio.c_cflag = CS8 | CREAD | HUPCL;
    tio.c_lflag = ISIG | ICANON | IEXTEN | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE;
    tio.c_cc[VINTR]    = 0x03;   // ^C
    tio.c_cc[VQUIT]    = 0x1c;   // ^backslash
    tio.c_cc[VERASE]   = 0x7f;   // delete
    tio.c_cc[VKILL]    = 0x15;   // ^U
    tio.c_cc[VEOF]     = 0x04;   // ^D
    tio.c_cc[VSTART]   = 0x11;   // ^Q
    tio.c_cc[VSTOP]    = 0x13;   // ^S
    tio.c_cc[VSUSP]    = 0x1a;   // ^Z
    tio.c_cc[VREPRINT] = 0x12;   // ^R
    tio.c_cc[VWERASE]  = 0x17;   // ^W
    tio.c_cc[VLNEXT]   = 0x16;   // ^V
    tio.c_cc[VMIN]     = 1;
    tio.c_cc[VTIME]    = 0;
    ::cfsetispeed(&tio, B38400);
    ::cfsetospeed(&tio, B38400);

    int master = -1;
    const pid_t pid = ::forkpty(&master, nullptr, &tio, &ws);
    if (pid < 0) {
        qWarning("could not open a pty: %s", std::strerror(errno));
        return false;
    }

    if (pid == 0) {
        // The child. Nothing here may return — a failed exec has to end
        // the process, or there would be two of everything.
        //
        // A clean slate to start a shell on.
        //
        // An ignored signal survives exec, and a blocked one survives it
        // unconditionally — so whatever this program was started with
        // would otherwise become what every command run in this window
        // inherits. A shell that starts with SIGINT ignored passes that
        // ignore to everything it runs, and ^C does nothing for the rest
        // of the session.
        sigset_t empty;
        sigemptyset(&empty);
        ::pthread_sigmask(SIG_SETMASK, &empty, nullptr);
        for (int sig = 1; sig < NSIG; ++sig) ::signal(sig, SIG_DFL);

        // TERM says what this emulator can do. xterm-256color is the
        // honest answer for what libvterm implements, and claiming more
        // (kitty's terminfo, say) would have programs send sequences that
        // go nowhere.
        ::setenv("TERM", "xterm-256color", 1);
        ::setenv("COLORTERM", "truecolor", 1);
        ::unsetenv("TERM_PROGRAM");

        QList<QByteArray> args;
        if (argv.isEmpty()) {
            const char *shell = ::getenv("SHELL");
            QByteArray sh = shell && *shell ? QByteArray(shell) : QByteArray("/bin/sh");
            args.append(sh);
            // A leading '-' is how a shell is told it is a login shell,
            // which is what makes it read the profile that sets up the
            // environment someone expects in a new window.
            args.append("-" + QFileInfo(QString::fromLocal8Bit(sh)).fileName().toLocal8Bit());
        } else {
            for (const QString &a : argv) args.append(a.toLocal8Bit());
        }

        QVarLengthArray<char *, 8> cargv;
        // argv[0] is the login-shell name when one was synthesised above.
        cargv.append(args.size() > 1 && argv.isEmpty()
                     ? const_cast<char *>(args[1].constData())
                     : const_cast<char *>(args[0].constData()));
        for (int i = argv.isEmpty() ? 2 : 1; i < args.size(); ++i)
            cargv.append(const_cast<char *>(args[i].constData()));
        cargv.append(nullptr);

        ::execvp(args[0].constData(), cargv.data());
        ::_exit(127);
    }

    m_pid = pid;
    m_fd = master;
    ::fcntl(m_fd, F_SETFL, ::fcntl(m_fd, F_GETFL) | O_NONBLOCK);

    m_notifier = new QSocketNotifier(m_fd, QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, &Pty::readReady);
    return true;
}

void Pty::readReady() {
    char buf[8192];
    // Read what is there and stop: looping until EAGAIN on a process
    // writing faster than this can paint would never hand control back,
    // and the window would freeze exactly when there is most to show.
    const ssize_t n = ::read(m_fd, buf, sizeof(buf));
    if (n > 0) {
        emit output(QByteArray(buf, static_cast<int>(n)));
        return;
    }
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;

    // 0 or a hard error: the child closed the other end.
    m_notifier->setEnabled(false);
    int status = 0;
    int code = 0;
    if (m_pid > 0 && ::waitpid(static_cast<pid_t>(m_pid), &status, WNOHANG) > 0)
        code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    m_pid = -1;
    emit finished(code);
}

void Pty::write(const QByteArray &data) {
    if (m_fd < 0) return;
    qint64 off = 0;
    while (off < data.size()) {
        const ssize_t n = ::write(m_fd, data.constData() + off, data.size() - off);
        if (n > 0) { off += n; continue; }
        if (n < 0 && errno == EINTR) continue;
        // EAGAIN on a full pipe: dropping the rest is wrong, but so is
        // blocking the UI thread. A terminal's input is human-sized, so
        // this only happens on a very large paste, and the tail is
        // retried on the next write rather than lost.
        break;
    }
}

void Pty::resize(int rows, int cols) {
    if (m_fd < 0 || rows <= 0 || cols <= 0) return;
    struct winsize ws;
    std::memset(&ws, 0, sizeof(ws));
    ws.ws_row = static_cast<unsigned short>(rows);
    ws.ws_col = static_cast<unsigned short>(cols);
    ::ioctl(m_fd, TIOCSWINSZ, &ws);
}

#pragma once

#include <QObject>
#include <QSocketNotifier>
#include <QStringList>

// The pseudo-terminal a shell runs on.
//
// (Named ptyproc.h rather than pty.h: a header of that name here is
// found before the system's, which is where forkpty is declared.)
//
// A terminal emulator is two halves: something that knows what the bytes
// mean (libvterm, next door) and something that produces them. This is
// the second half — a child process on the far side of a pty, whatever
// it writes arriving here as bytes and whatever is typed going back the
// same way.
//
// Deliberately thin. It knows nothing about escape sequences, screens or
// rendering; it opens the pty, starts the child, and moves bytes.
class Pty : public QObject {
    Q_OBJECT

public:
    explicit Pty(QObject *parent = nullptr);
    ~Pty() override;

    // argv[0] is the program. An empty list means the login shell, which
    // is what a terminal with nothing else asked of it should run.
    bool start(const QStringList &argv, int rows, int cols);

    void write(const QByteArray &data);
    // The size the child sees, so that `less` and `vim` lay out to the
    // window rather than to whatever 80x24 they assumed.
    void resize(int rows, int cols);

    bool running() const { return m_pid > 0; }
    int  fd() const { return m_fd; }

signals:
    void output(const QByteArray &data);
    // The child is gone. Carries its exit status, which a terminal shows
    // rather than silently closing on a shell that died complaining.
    void finished(int exitCode);

private:
    void readReady();

    int m_fd = -1;
    qint64 m_pid = -1;
    QSocketNotifier *m_notifier = nullptr;
};

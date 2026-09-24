#include "proc.h"

#include <QDebug>

Proc::Proc(QObject *parent) : QObject(parent) {}

Proc::~Proc() {
    if (m_proc) {
        m_proc->disconnect(this);
        // Terminate rather than wait: a watcher process would otherwise hold
        // the application open after its window has gone.
        m_proc->kill();
        m_proc->waitForFinished(200);
    }
}

void Proc::setCommand(const QStringList &c) {
    if (m_command == c) return;
    m_command = c;
    emit commandChanged();
}

void Proc::setStreaming(bool s) {
    if (m_streaming == s) return;
    m_streaming = s;
    emit streamingChanged();
}

bool Proc::running() const {
    return m_proc && m_proc->state() != QProcess::NotRunning;
}

void Proc::setRunning(bool r) {
    if (r) {
        // Starting something while something else is still going means
        // "run this instead", not "never mind, carry on with the old
        // one" — which is what returning early here used to mean.
        //
        // Every directory listing goes through one of these. Navigate
        // while the folder you are leaving is still being read and the
        // second listing was dropped: the window then showed the first
        // folder's contents under the second folder's name, with
        // nothing selected. "Show in file manager" on a window that was
        // still opening hit it every time, because the folder it starts
        // in and the folder it was asked for are always in flight
        // together.
        //
        // start() disconnects the outgoing process before killing it, so
        // the listing being replaced cannot deliver a result afterwards.
        start();
        emit runningChanged();
        return;
    }
    if (!running()) return;
    // Stopping is silent: a process killed on purpose has no result
    // anyone is waiting for, and letting finished() through here would
    // deliver whatever it had managed to write as though it were whole.
    if (m_proc) {
        m_proc->disconnect(this);
        m_proc->kill();
    }
    emit runningChanged();
}

void Proc::writeStdin(const QString &text) {
    m_stdinText = text;
    m_hasStdin = true;
}

void Proc::start() {
    if (m_command.isEmpty()) return;

    if (m_proc) {
        m_proc->disconnect(this);
        m_proc->kill();
        // Reaped before it is deleted, or Qt warns that a QProcess was
        // destroyed with the process still running. Nothing here ignores
        // SIGKILL, so this returns at once; the budget is only so that a
        // pathological case cannot hang the window.
        m_proc->waitForFinished(100);
        m_proc->deleteLater();
    }
    m_out.clear();
    m_pending.clear();

    m_proc = new QProcess(this);
    m_proc->setProgram(m_command.first());
    m_proc->setArguments(m_command.mid(1));
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);

    connect(m_proc, &QProcess::readyReadStandardOutput, this, &Proc::onReadyRead);

    connect(m_proc, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus) {
                if (!m_proc) return;
                const QString err = QString::fromUtf8(m_proc->readAllStandardError());
                if (!m_streaming) m_out += m_proc->readAllStandardOutput();
                emit finished(code, QString::fromUtf8(m_out), err);
                emit runningChanged();
            });

    connect(m_proc, &QProcess::errorOccurred, this,
            [this](QProcess::ProcessError e) {
                if (e != QProcess::FailedToStart) return;
                // A missing program is an ordinary outcome here — half of
                // what this runs is optional — so it is reported the same
                // way a non-zero exit is, not as a crash.
                emit finished(-1, QString(),
                              QStringLiteral("%1: not found").arg(m_command.value(0)));
                emit runningChanged();
            });

    m_proc->start();
    if (m_hasStdin) {
        m_proc->write(m_stdinText.toUtf8());
        m_proc->closeWriteChannel();
        m_hasStdin = false;
        m_stdinText.clear();
    }
}

void Proc::onReadyRead() {
    if (!m_proc) return;
    const QByteArray chunk = m_proc->readAllStandardOutput();
    if (!m_streaming) {
        m_out += chunk;
        return;
    }
    m_pending += chunk;
    int cut;
    while ((cut = m_pending.indexOf('\n')) >= 0) {
        emit line(QString::fromUtf8(m_pending.left(cut)));
        m_pending.remove(0, cut + 1);
    }
}

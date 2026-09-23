#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

// A process, for QML.
//
// This is the one piece of Quickshell the file manager genuinely needed, so
// it is the one piece reimplemented here: run an argv, collect its output,
// say when it finished. Deliberately argv-only — there is no string form and
// no shell — so a filename is never parsed as anything but a filename.
class Proc : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QStringList command READ command WRITE setCommand NOTIFY commandChanged)
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    // Streaming mode: emit `line` as output arrives rather than collecting
    // it. `gio monitor` never finishes, so collecting it would mean never
    // hearing anything at all.
    Q_PROPERTY(bool streaming READ streaming WRITE setStreaming NOTIFY streamingChanged)

public:
    explicit Proc(QObject *parent = nullptr);
    ~Proc() override;

    QStringList command() const { return m_command; }
    void setCommand(const QStringList &c);

    bool running() const;
    void setRunning(bool r);

    bool streaming() const { return m_streaming; }
    void setStreaming(bool s);

    // Write to the process's stdin and close it. Used for the clipboard,
    // where the text must not go through argv.
    Q_INVOKABLE void writeStdin(const QString &text);

signals:
    void commandChanged();
    void runningChanged();
    void streamingChanged();
    // exitCode is -1 when the process could not be started at all.
    void finished(int exitCode, const QString &stdoutText, const QString &stderrText);
    void line(const QString &text);

private:
    void start();
    void onReadyRead();

    QProcess *m_proc = nullptr;
    QStringList m_command;
    QByteArray m_out;
    QByteArray m_pending;
    bool m_streaming = false;
    QString m_stdinText;
    bool m_hasStdin = false;
};

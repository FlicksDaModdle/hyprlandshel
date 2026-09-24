#pragma once

#include <QObject>
#include <QStringList>
#include <QVariantMap>

// `hyprshell-files --pick`: the same dialog the portal puts up, asked for
// from a command line and answering on stdout.
//
// The portal is the right way for an ordinary application to get a file
// dialog, and everything that can use it should. The shell is not an
// ordinary application: Quickshell has no file dialog of its own and no
// generic way to make a portal call and wait for the Response signal, so
// the icon maker had a drop zone and a box to type a path into and
// nothing else. This is the other door into the same dialog — run the
// program, read the answer off stdout.
//
// One path per line, nothing else on stdout, exit 0 if something was
// chosen and 1 if it was cancelled. That is the whole interface, and it
// is the one a shell script or a Quickshell Process can read without
// parsing anything.
class Picker : public QObject {
    Q_OBJECT
    // Whether --pick was asked for at all. Main.qml reads this to decide
    // between showing the browser and putting up a dialog.
    Q_PROPERTY(bool wanted READ wanted CONSTANT)
    // The dialog's settings, in the shape FileDialog's properties take.
    Q_PROPERTY(QVariantMap request READ request CONSTANT)

public:
    explicit Picker(QObject *parent = nullptr);

    // Reads the arguments. Returns false and leaves `wanted` false when
    // --pick is absent; returns false with an error printed when it is
    // present but the rest does not make sense.
    bool parse(const QStringList &args);

    [[nodiscard]] bool wanted() const { return m_wanted; }
    [[nodiscard]] QVariantMap request() const { return m_request; }

    // What to print if usage was wrong, for main() to show.
    [[nodiscard]] QString error() const { return m_error; }

public slots:
    // Called from QML when the dialog closes. An empty list is a
    // cancellation. Prints, and ends the process — there is nothing else
    // for it to do.
    void finish(const QStringList &paths);

private:
    bool m_wanted = false;
    QVariantMap m_request;
    QString m_error;
};

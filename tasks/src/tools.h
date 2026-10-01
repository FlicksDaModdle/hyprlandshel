#pragma once

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class AppIndex;

// What the views other than Processes and Performance need from the system,
// each read on demand rather than every second.
class Tools : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Tools(QObject *parent = nullptr);

    // ── Startup apps ──────────────────────────────────────────────────────
    // [{ id, name, exec, icon, enabled, source: "autostart" | "systemd",
    //    path, system (from /etc), comment }]
    Q_INVOKABLE QVariantList startupEntries() const;
    // Disabling a system-wide entry writes an override into
    // ~/.config/autostart with Hidden=true, which is what the spec says
    // turns it off for this user; enabling removes the override.
    Q_INVOKABLE bool setAutostart(const QString &id, bool enabled);
    Q_INVOKABLE bool addAutostart(const QString &desktopId);
    Q_INVOKABLE bool removeAutostart(const QString &id);
    Q_INVOKABLE QVariantList applications() const;

    // ── Connections ───────────────────────────────────────────────────────
    // Every TCP and UDP socket, with the process that owns it where it is
    // yours to see: [{ proto, local, localPort, remote, remotePort, state,
    // pid, process, uid, inode }]
    Q_INVOKABLE QVariantList connections() const;

    // ── Drivers ───────────────────────────────────────────────────────────
    Q_INVOKABLE QVariantList pciDevices() const;
    Q_INVOKABLE QVariantList usbDevices() const;
    Q_INVOKABLE QVariantList kernelModules() const;
    Q_INVOKABLE QVariantMap moduleInfo(const QString &name) const;

    // ── Installed apps ────────────────────────────────────────────────────
    // Asynchronous: pacman and flatpak each take a moment. Answers with
    // packagesLoaded([{ name, version, description, size, installed,
    // explicit, source: "pacman" | "flatpak", app (has a .desktop) }]).
    Q_INVOKABLE void loadPackages();

    // ── Services ──────────────────────────────────────────────────────────
    // servicesLoaded(user, [{ unit, description, active, sub, load, enabled,
    // pid, memory, cpuSeconds }])
    Q_INVOKABLE void loadServices(bool user);
    // start | stop | restart | enable | disable. System services go through
    // polkit, which asks for a password through the session's agent.
    Q_INVOKABLE void serviceAction(bool user, const QString &unit, const QString &action);
    Q_INVOKABLE void sessions();

    // ── odds and ends ─────────────────────────────────────────────────────
    Q_INVOKABLE void focusWindow(const QString &address) const;
    Q_INVOKABLE void showInFolder(const QString &path) const;
    Q_INVOKABLE void openTerminal(const QStringList &argv) const;
    Q_INVOKABLE void runDetached(const QStringList &argv) const;
    Q_INVOKABLE QString readFile(const QString &path) const;
    Q_INVOKABLE bool writeFile(const QString &path, const QString &text) const;
    Q_INVOKABLE QString configPath() const;
    Q_INVOKABLE QString dataPath() const;
    Q_INVOKABLE QString home() const;

signals:
    void packagesLoaded(const QVariantList &packages);
    void servicesLoaded(bool user, const QVariantList &services);
    void sessionsLoaded(const QVariantList &sessions);
    void actionDone(bool ok, const QString &message);

private:
    AppIndex *m_apps;
};

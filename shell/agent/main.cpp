// hyprshell-agent — what KDE's background services do for its Bluetooth and
// network settings, for the shell.
//
//   Bluetooth   the adapter and its devices, live from BlueZ (no polling),
//               and the commands on them: power, discovery, pair, connect,
//               trust, remove. And a pairing *agent*: the program BlueZ
//               asks "does 123456 match what the device shows?", "what PIN
//               did the keyboard print?" and "may this phone pair?". Without
//               one, any device that wants an answer fails to pair with
//               org.bluez.Error.AuthenticationFailed — which is what the
//               shell used to hit, pairing through a one-shot bluetoothctl
//               that could not ask anybody anything.
//
//   Networks    a NetworkManager secret agent: when NetworkManager needs a
//               password it has not got — a Wi-Fi network whose saved
//               password is wrong, an 802.1X network set up elsewhere that
//               keeps its secrets per user, as KDE's do — it asks the agents
//               in the session. Without one in the session, connecting fails
//               with "Secrets were required, but not provided".
//
// It talks to the shell (services/Bluetooth.qml, services/Network.qml) in
// JSON, one object per line: events on stdout, commands on stdin. When stdin
// closes — the shell quit or reloaded — it exits, and its agents go with it.
//
// HYPRSHELL_AGENT_BUS=session runs it against the session bus instead of the
// system bus, for testing against a stand-in BlueZ and NetworkManager.

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusContext>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSocketNotifier>
#include <QTimer>

#include <cstdio>
#include <functional>
#include <unistd.h>

typedef QMap<QString, QVariantMap> InterfaceMap;              // a{sa{sv}}
typedef QMap<QDBusObjectPath, InterfaceMap> ManagedObjects;   // a{oa{sa{sv}}}
Q_DECLARE_METATYPE(InterfaceMap)
Q_DECLARE_METATYPE(ManagedObjects)

static const char *BLUEZ = "org.bluez";
static const char *NM = "org.freedesktop.NetworkManager";

static void emitEvent(const QJsonObject &o)
{
    QByteArray line = QJsonDocument(o).toJson(QJsonDocument::Compact);
    line.append('\n');
    fwrite(line.constData(), 1, size_t(line.size()), stdout);
    fflush(stdout);
}

static QString macFromPath(const QString &path)
{
    // /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
    const int i = path.lastIndexOf(QStringLiteral("/dev_"));
    if (i < 0) return QString();
    return path.mid(i + 5).replace(QLatin1Char('_'), QLatin1Char(':'));
}

// ══ Bluetooth ════════════════════════════════════════════════════════════

class Bluetooth;

// org.bluez.Agent1. Each question BlueZ asks becomes a "bt-request" event
// with an id, and the call is held open until the shell answers it with a
// "bt-reply" — or BlueZ gives up and calls Cancel.
class BtAgent : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.bluez.Agent1")
public:
    BtAgent(QDBusConnection bus, Bluetooth *bt) : QObject(), m_bus(bus), m_bt(bt) {}

    void reply(int id, bool accept, const QString &value);

public slots:
    void Release() {}
    QString RequestPinCode(const QDBusObjectPath &device)
    {
        hold(QStringLiteral("pin"), device, {});
        return QString();
    }
    void DisplayPinCode(const QDBusObjectPath &device, const QString &pincode)
    {
        emitDisplay(QStringLiteral("pin"), device, pincode, -1);
    }
    uint RequestPasskey(const QDBusObjectPath &device)
    {
        hold(QStringLiteral("passkey"), device, {});
        return 0;
    }
    void DisplayPasskey(const QDBusObjectPath &device, uint passkey, ushort entered)
    {
        emitDisplay(QStringLiteral("passkey"), device,
                    QStringLiteral("%1").arg(passkey, 6, 10, QLatin1Char('0')), entered);
    }
    void RequestConfirmation(const QDBusObjectPath &device, uint passkey)
    {
        hold(QStringLiteral("confirm"), device,
             { { QStringLiteral("passkey"), QStringLiteral("%1").arg(passkey, 6, 10, QLatin1Char('0')) } });
    }
    void RequestAuthorization(const QDBusObjectPath &device)
    {
        hold(QStringLiteral("authorize"), device, {});
    }
    void AuthorizeService(const QDBusObjectPath &device, const QString &uuid);
    void Cancel()
    {
        // BlueZ cancels whatever it asked last; there is only ever one
        // question in flight per pairing.
        for (auto it = m_pending.begin(); it != m_pending.end(); ++it)
            m_bus.send(it.value().createErrorReply(QStringLiteral("org.bluez.Error.Canceled"),
                                                   QStringLiteral("Canceled")));
        m_pending.clear();
        m_kinds.clear();
        emitEvent({ { "ev", "bt-cancel" } });
    }

private:
    void hold(const QString &kind, const QDBusObjectPath &device, const QJsonObject &extra);
    void emitDisplay(const QString &kind, const QDBusObjectPath &device, const QString &code, int entered);

    QDBusConnection m_bus;
    Bluetooth *m_bt;
    QMap<int, QDBusMessage> m_pending;
    QMap<int, QString> m_kinds;
    int m_next = 1;
};

class Bluetooth : public QObject
{
    Q_OBJECT
public:
    explicit Bluetooth(QDBusConnection bus) : QObject(), m_bus(bus)
    {
        m_agent = new BtAgent(bus, this);
        m_snapshot.setSingleShot(true);
        m_snapshot.setInterval(40);
        connect(&m_snapshot, &QTimer::timeout, this, &Bluetooth::emitSnapshot);
    }

    void start()
    {
        m_bus.registerObject(QStringLiteral("/org/hyprshell/agent/bluez"), m_agent,
                             QDBusConnection::ExportAllSlots);

        m_bus.connect(BLUEZ, QStringLiteral("/"), QStringLiteral("org.freedesktop.DBus.ObjectManager"),
                      QStringLiteral("InterfacesAdded"), this, SLOT(onInterfacesAdded(QDBusMessage)));
        m_bus.connect(BLUEZ, QStringLiteral("/"), QStringLiteral("org.freedesktop.DBus.ObjectManager"),
                      QStringLiteral("InterfacesRemoved"), this, SLOT(onInterfacesRemoved(QDBusMessage)));
        m_bus.connect(BLUEZ, QString(), QStringLiteral("org.freedesktop.DBus.Properties"),
                      QStringLiteral("PropertiesChanged"), this, SLOT(onPropertiesChanged(QDBusMessage)));

        auto *watch = new QDBusServiceWatcher(BLUEZ, m_bus,
            QDBusServiceWatcher::WatchForRegistration | QDBusServiceWatcher::WatchForUnregistration, this);
        connect(watch, &QDBusServiceWatcher::serviceRegistered, this, [this] { load(); });
        connect(watch, &QDBusServiceWatcher::serviceUnregistered, this, [this] {
            m_adapters.clear();
            m_devices.clear();
            m_battery.clear();
            m_running = false;
            m_snapshot.start();
        });

        if (m_bus.interface()->isServiceRegistered(BLUEZ)) load();
        else m_snapshot.start();
    }

    QString deviceName(const QString &path) const
    {
        const QVariantMap d = m_devices.value(path);
        return d.value(QStringLiteral("Alias"), d.value(QStringLiteral("Name"), macFromPath(path))).toString();
    }
    bool deviceTrusted(const QString &path) const
    {
        return m_devices.value(path).value(QStringLiteral("Trusted")).toBool();
    }

    void command(const QJsonObject &c)
    {
        const QString cmd = c.value(QStringLiteral("cmd")).toString();
        const QString mac = c.value(QStringLiteral("mac")).toString();
        const bool on = c.value(QStringLiteral("on")).toBool();

        if (cmd == QLatin1String("bt-reply")) {
            m_agent->reply(c.value(QStringLiteral("id")).toInt(), c.value(QStringLiteral("accept")).toBool(),
                           c.value(QStringLiteral("value")).toString());
        } else if (cmd == QLatin1String("bt-power")) {
            setAdapter(QStringLiteral("Powered"), on, QStringLiteral("power"));
        } else if (cmd == QLatin1String("bt-discoverable")) {
            setAdapter(QStringLiteral("Discoverable"), on, QStringLiteral("discoverable"));
        } else if (cmd == QLatin1String("bt-scan")) {
            // Discovery started by this process lasts while it runs, so the
            // shell stops it when the pane closes rather than relying on a
            // timeout; BlueZ also stops it if this process goes away.
            m_wantScan = on;
            callAdapter(on ? QStringLiteral("StartDiscovery") : QStringLiteral("StopDiscovery"), {},
                        QStringLiteral("scan"), QString());
        } else if (cmd == QLatin1String("bt-pair")) {
            pair(mac);
        } else if (cmd == QLatin1String("bt-connect")) {
            callDevice(mac, QStringLiteral("Connect"), QStringLiteral("connect"), 45000);
        } else if (cmd == QLatin1String("bt-disconnect")) {
            callDevice(mac, QStringLiteral("Disconnect"), QStringLiteral("disconnect"), 20000);
        } else if (cmd == QLatin1String("bt-cancel")) {
            callDevice(mac, QStringLiteral("CancelPairing"), QStringLiteral("cancel"), 10000);
        } else if (cmd == QLatin1String("bt-trust")) {
            setDevice(mac, QStringLiteral("Trusted"), on, QStringLiteral("trust"));
        } else if (cmd == QLatin1String("bt-remove")) {
            const QString path = pathFor(mac);
            if (path.isEmpty()) return;
            callAdapter(QStringLiteral("RemoveDevice"), { QVariant::fromValue(QDBusObjectPath(path)) },
                        QStringLiteral("remove"), mac);
        } else if (cmd == QLatin1String("bt-hello")) {
            m_snapshot.start();
        }
    }

private slots:
    void onInterfacesAdded(const QDBusMessage &msg)
    {
        const QList<QVariant> a = msg.arguments();
        if (a.size() < 2) return;
        const QString path = a.at(0).value<QDBusObjectPath>().path();
        const InterfaceMap ifaces = qdbus_cast<InterfaceMap>(a.at(1));
        absorb(path, ifaces);
        m_snapshot.start();
    }
    void onInterfacesRemoved(const QDBusMessage &msg)
    {
        const QList<QVariant> a = msg.arguments();
        if (a.size() < 2) return;
        const QString path = a.at(0).value<QDBusObjectPath>().path();
        const QStringList ifaces = a.at(1).toStringList();
        if (ifaces.contains(QStringLiteral("org.bluez.Device1"))) m_devices.remove(path);
        if (ifaces.contains(QStringLiteral("org.bluez.Adapter1"))) m_adapters.remove(path);
        if (ifaces.contains(QStringLiteral("org.bluez.Battery1"))) m_battery.remove(path);
        m_snapshot.start();
    }
    void onPropertiesChanged(const QDBusMessage &msg)
    {
        const QList<QVariant> a = msg.arguments();
        if (a.size() < 2) return;
        const QString iface = a.at(0).toString();
        const QVariantMap changed = qdbus_cast<QVariantMap>(a.at(1));
        const QStringList invalidated = a.size() > 2 ? a.at(2).toStringList() : QStringList();
        const QString path = msg.path();
        QMap<QString, QVariantMap> *store = nullptr;
        if (iface == QLatin1String("org.bluez.Device1")) store = &m_devices;
        else if (iface == QLatin1String("org.bluez.Adapter1")) store = &m_adapters;
        else if (iface == QLatin1String("org.bluez.Battery1")) {
            if (changed.contains(QStringLiteral("Percentage")))
                m_battery[path] = changed.value(QStringLiteral("Percentage")).toInt();
            m_snapshot.start();
            return;
        }
        if (!store || !store->contains(path)) return;
        QVariantMap &props = (*store)[path];
        for (auto it = changed.begin(); it != changed.end(); ++it) props[it.key()] = it.value();
        for (const QString &k : invalidated) props.remove(k);
        m_snapshot.start();
    }

private:
    void load()
    {
        QDBusMessage m = QDBusMessage::createMethodCall(BLUEZ, QStringLiteral("/"),
            QStringLiteral("org.freedesktop.DBus.ObjectManager"), QStringLiteral("GetManagedObjects"));
        auto *w = new QDBusPendingCallWatcher(m_bus.asyncCall(m), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<ManagedObjects> r = *w;
            if (r.isError()) {
                emitEvent({ { "ev", "bt-error" }, { "op", "load" },
                            { "error", r.error().name() }, { "message", r.error().message() } });
                return;
            }
            m_adapters.clear();
            m_devices.clear();
            m_battery.clear();
            const ManagedObjects objs = r.value();
            for (auto it = objs.begin(); it != objs.end(); ++it) absorb(it.key().path(), it.value());
            m_running = true;
            registerAgent();
            m_snapshot.start();
        });
    }

    void absorb(const QString &path, const InterfaceMap &ifaces)
    {
        if (ifaces.contains(QStringLiteral("org.bluez.Adapter1")))
            m_adapters[path] = ifaces.value(QStringLiteral("org.bluez.Adapter1"));
        if (ifaces.contains(QStringLiteral("org.bluez.Device1")))
            m_devices[path] = ifaces.value(QStringLiteral("org.bluez.Device1"));
        if (ifaces.contains(QStringLiteral("org.bluez.Battery1")))
            m_battery[path] = ifaces.value(QStringLiteral("org.bluez.Battery1"))
                                  .value(QStringLiteral("Percentage")).toInt();
    }

    // KeyboardDisplay: the shell can show a code and take one typed in,
    // so every pairing method a device might ask for is on the table.
    void registerAgent()
    {
        const QDBusObjectPath me(QStringLiteral("/org/hyprshell/agent/bluez"));
        QDBusMessage reg = QDBusMessage::createMethodCall(BLUEZ, QStringLiteral("/org/bluez"),
            QStringLiteral("org.bluez.AgentManager1"), QStringLiteral("RegisterAgent"));
        reg << QVariant::fromValue(me) << QStringLiteral("KeyboardDisplay");
        auto *w = new QDBusPendingCallWatcher(m_bus.asyncCall(reg), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [this, me](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<> r = *w;
            if (r.isError() && r.error().name() != QLatin1String("org.bluez.Error.AlreadyExists")) {
                emitEvent({ { "ev", "bt-agent" }, { "ok", false }, { "error", r.error().name() },
                            { "message", r.error().message() } });
                return;
            }
            // The default agent is the one asked about pairings nobody here
            // started — a phone or a keyboard asking to pair with this.
            QDBusMessage def = QDBusMessage::createMethodCall(BLUEZ, QStringLiteral("/org/bluez"),
                QStringLiteral("org.bluez.AgentManager1"), QStringLiteral("RequestDefaultAgent"));
            def << QVariant::fromValue(me);
            auto *w2 = new QDBusPendingCallWatcher(m_bus.asyncCall(def), this);
            connect(w2, &QDBusPendingCallWatcher::finished, this, [](QDBusPendingCallWatcher *w2) {
                w2->deleteLater();
                QDBusPendingReply<> r2 = *w2;
                emitEvent({ { "ev", "bt-agent" }, { "ok", true }, { "default", !r2.isError() } });
            });
        });
    }

    QString adapterPath() const
    {
        if (m_adapters.contains(QStringLiteral("/org/bluez/hci0"))) return QStringLiteral("/org/bluez/hci0");
        return m_adapters.isEmpty() ? QString() : m_adapters.firstKey();
    }

    QString pathFor(const QString &mac) const
    {
        for (auto it = m_devices.begin(); it != m_devices.end(); ++it)
            if (it.value().value(QStringLiteral("Address")).toString().compare(mac, Qt::CaseInsensitive) == 0)
                return it.key();
        return QString();
    }

    void report(QDBusPendingCallWatcher *w, const QString &op, const QString &mac,
                std::function<void()> then = nullptr)
    {
        connect(w, &QDBusPendingCallWatcher::finished, this, [op, mac, then](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<> r = *w;
            if (r.isError()) {
                emitEvent({ { "ev", "bt-error" }, { "op", op }, { "mac", mac },
                            { "error", r.error().name() }, { "message", r.error().message() } });
                emitEvent({ { "ev", "bt-done" }, { "op", op }, { "mac", mac }, { "ok", false } });
                return;
            }
            if (then) then();
            else emitEvent({ { "ev", "bt-done" }, { "op", op }, { "mac", mac }, { "ok", true } });
        });
    }

    void setAdapter(const QString &prop, bool on, const QString &op)
    {
        const QString path = adapterPath();
        if (path.isEmpty()) return;
        QDBusMessage m = QDBusMessage::createMethodCall(BLUEZ, path,
            QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Set"));
        m << QStringLiteral("org.bluez.Adapter1") << prop << QVariant::fromValue(QDBusVariant(on));
        report(new QDBusPendingCallWatcher(m_bus.asyncCall(m), this), op, QString());
    }

    void setDevice(const QString &mac, const QString &prop, bool on, const QString &op,
                   std::function<void()> then = nullptr)
    {
        const QString path = pathFor(mac);
        if (path.isEmpty()) return;
        QDBusMessage m = QDBusMessage::createMethodCall(BLUEZ, path,
            QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Set"));
        m << QStringLiteral("org.bluez.Device1") << prop << QVariant::fromValue(QDBusVariant(on));
        report(new QDBusPendingCallWatcher(m_bus.asyncCall(m), this), op, mac, then);
    }

    void callAdapter(const QString &method, const QList<QVariant> &args, const QString &op, const QString &mac)
    {
        const QString path = adapterPath();
        if (path.isEmpty()) return;
        QDBusMessage m = QDBusMessage::createMethodCall(BLUEZ, path, QStringLiteral("org.bluez.Adapter1"), method);
        m.setArguments(args);
        report(new QDBusPendingCallWatcher(m_bus.asyncCall(m), this), op, mac);
    }

    void callDevice(const QString &mac, const QString &method, const QString &op, int timeout,
                    std::function<void()> then = nullptr)
    {
        const QString path = pathFor(mac);
        if (path.isEmpty()) {
            emitEvent({ { "ev", "bt-error" }, { "op", op }, { "mac", mac },
                        { "error", "org.bluez.Error.DoesNotExist" }, { "message", "Device is gone" } });
            return;
        }
        emitEvent({ { "ev", "bt-busy" }, { "op", op }, { "mac", mac } });
        QDBusMessage m = QDBusMessage::createMethodCall(BLUEZ, path, QStringLiteral("org.bluez.Device1"), method);
        report(new QDBusPendingCallWatcher(m_bus.asyncCall(m, timeout), this), op, mac, then);
    }

    // Pair, then trust, then connect: what "pair" means to anyone who is
    // not reading BlueZ's documentation. Trusted is what lets the device
    // reconnect by itself later without asking again.
    void pair(const QString &mac)
    {
        const QString path = pathFor(mac);
        const bool already = m_devices.value(path).value(QStringLiteral("Paired")).toBool();
        auto connectIt = [this, mac] {
            callDevice(mac, QStringLiteral("Connect"), QStringLiteral("connect"), 45000);
        };
        auto trustIt = [this, mac, connectIt] {
            setDevice(mac, QStringLiteral("Trusted"), true, QStringLiteral("trust"), connectIt);
        };
        if (already) { trustIt(); return; }
        // Discovery competes with pairing for the radio, and some devices
        // fail to pair while it runs.
        if (m_adapters.value(adapterPath()).value(QStringLiteral("Discovering")).toBool())
            callAdapter(QStringLiteral("StopDiscovery"), {}, QStringLiteral("scan"), QString());
        callDevice(mac, QStringLiteral("Pair"), QStringLiteral("pair"), 120000, trustIt);
    }

    void emitSnapshot()
    {
        QJsonObject ev{ { "ev", "bt" }, { "available", m_running && !m_adapters.isEmpty() } };
        const QString ap = adapterPath();
        if (!ap.isEmpty()) {
            const QVariantMap a = m_adapters.value(ap);
            ev.insert(QStringLiteral("adapter"), QJsonObject{
                { "path", ap },
                { "name", a.value(QStringLiteral("Alias"), a.value(QStringLiteral("Name"))).toString() },
                { "address", a.value(QStringLiteral("Address")).toString() },
                { "powered", a.value(QStringLiteral("Powered")).toBool() },
                { "discoverable", a.value(QStringLiteral("Discoverable")).toBool() },
                { "discovering", a.value(QStringLiteral("Discovering")).toBool() },
                { "pairable", a.value(QStringLiteral("Pairable")).toBool() } });
        }
        QJsonArray devs;
        for (auto it = m_devices.begin(); it != m_devices.end(); ++it) {
            const QVariantMap d = it.value();
            if (!ap.isEmpty() && d.value(QStringLiteral("Adapter")).value<QDBusObjectPath>().path() != ap
                && d.contains(QStringLiteral("Adapter")))
                continue;
            const QString mac = d.value(QStringLiteral("Address")).toString();
            QJsonObject o{
                { "path", it.key() },
                { "mac", mac },
                { "name", d.value(QStringLiteral("Alias"), d.value(QStringLiteral("Name"), mac)).toString() },
                // A device that has said what it is called, as against one
                // known only by its address — most of what a scan turns up.
                { "named", d.contains(QStringLiteral("Name")) },
                { "icon", d.value(QStringLiteral("Icon")).toString() },
                { "paired", d.value(QStringLiteral("Paired")).toBool() || d.value(QStringLiteral("Bonded")).toBool() },
                { "trusted", d.value(QStringLiteral("Trusted")).toBool() },
                { "connected", d.value(QStringLiteral("Connected")).toBool() },
                { "blocked", d.value(QStringLiteral("Blocked")).toBool() },
                { "battery", m_battery.value(it.key(), -1) } };
            if (d.contains(QStringLiteral("RSSI"))) o.insert(QStringLiteral("rssi"), d.value(QStringLiteral("RSSI")).toInt());
            devs.append(o);
        }
        ev.insert(QStringLiteral("devices"), devs);
        emitEvent(ev);
    }

    QDBusConnection m_bus;
    BtAgent *m_agent;
    QTimer m_snapshot;
    bool m_running = false;
    bool m_wantScan = false;
    QMap<QString, QVariantMap> m_adapters;
    QMap<QString, QVariantMap> m_devices;
    QMap<QString, int> m_battery;
};

void BtAgent::hold(const QString &kind, const QDBusObjectPath &device, const QJsonObject &extra)
{
    setDelayedReply(true);
    const int id = m_next++;
    m_pending.insert(id, message());
    m_kinds.insert(id, kind);
    QJsonObject ev{ { "ev", "bt-request" }, { "id", id }, { "kind", kind },
                    { "mac", macFromPath(device.path()) }, { "name", m_bt->deviceName(device.path()) } };
    for (auto it = extra.begin(); it != extra.end(); ++it) ev.insert(it.key(), it.value());
    emitEvent(ev);
}

void BtAgent::emitDisplay(const QString &kind, const QDBusObjectPath &device, const QString &code, int entered)
{
    QJsonObject ev{ { "ev", "bt-display" }, { "kind", kind }, { "code", code },
                    { "mac", macFromPath(device.path()) }, { "name", m_bt->deviceName(device.path()) } };
    if (entered >= 0) ev.insert(QStringLiteral("entered"), entered);
    emitEvent(ev);
}

void BtAgent::AuthorizeService(const QDBusObjectPath &device, const QString &uuid)
{
    // A device already trusted is allowed its services without asking —
    // BlueZ normally does not even ask for those.
    if (m_bt->deviceTrusted(device.path())) return;
    hold(QStringLiteral("service"), device, { { "uuid", uuid } });
}

void BtAgent::reply(int id, bool accept, const QString &value)
{
    if (!m_pending.contains(id)) return;
    const QDBusMessage msg = m_pending.take(id);
    const QString kind = m_kinds.take(id);
    if (!accept) {
        m_bus.send(msg.createErrorReply(QStringLiteral("org.bluez.Error.Rejected"),
                                        QStringLiteral("Rejected")));
        return;
    }
    if (kind == QLatin1String("pin"))
        m_bus.send(msg.createReply(QVariant(value)));
    else if (kind == QLatin1String("passkey"))
        m_bus.send(msg.createReply(QVariant::fromValue(uint(value.toUInt()))));
    else
        m_bus.send(msg.createReply());
}

// ══ NetworkManager secret agent ══════════════════════════════════════════

class SecretAgent : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.NetworkManager.SecretAgent")
public:
    explicit SecretAgent(QDBusConnection bus) : QObject(), m_bus(bus) {}

    void start()
    {
        // NetworkManager calls every agent at this one path.
        m_bus.registerObject(QStringLiteral("/org/freedesktop/NetworkManager/SecretAgent"), this,
                             QDBusConnection::ExportAllSlots);
        auto *watch = new QDBusServiceWatcher(NM, m_bus, QDBusServiceWatcher::WatchForRegistration, this);
        connect(watch, &QDBusServiceWatcher::serviceRegistered, this, [this] { registerAgent(); });
        if (m_bus.interface()->isServiceRegistered(NM)) registerAgent();
    }

    void command(const QJsonObject &c)
    {
        const QString cmd = c.value(QStringLiteral("cmd")).toString();
        if (cmd != QLatin1String("nm-reply")) return;
        const int id = c.value(QStringLiteral("id")).toInt();
        if (!m_pending.contains(id)) return;
        const QDBusMessage msg = m_pending.take(id);
        const QString setting = m_settings.take(id);
        m_paths.remove(id);
        const QJsonObject secrets = c.value(QStringLiteral("secrets")).toObject();
        if (secrets.isEmpty()) {
            m_bus.send(msg.createErrorReply(
                QStringLiteral("org.freedesktop.NetworkManager.SecretAgent.UserCanceled"),
                QStringLiteral("Canceled")));
            return;
        }
        QVariantMap inner;
        for (auto it = secrets.begin(); it != secrets.end(); ++it) inner.insert(it.key(), it.value().toString());
        InterfaceMap out;
        out.insert(setting, inner);
        m_bus.send(msg.createReply(QVariant::fromValue(out)));
    }

public slots:
    InterfaceMap GetSecrets(const InterfaceMap &connection, const QDBusObjectPath &path,
                            const QString &setting, const QStringList &hints, uint flags)
    {
        const QVariantMap con = connection.value(QStringLiteral("connection"));
        const QVariantMap wifi = connection.value(QStringLiteral("802-11-wireless"));
        const QVariantMap sec = connection.value(QStringLiteral("802-11-wireless-security"));
        const QVariantMap x = connection.value(QStringLiteral("802-1x"));
        const QString keyMgmt = sec.value(QStringLiteral("key-mgmt")).toString();
        const QStringList eap = x.value(QStringLiteral("eap")).toStringList();

        QStringList fields;
        if (setting == QLatin1String("802-11-wireless-security")) {
            if (keyMgmt == QLatin1String("wpa-psk") || keyMgmt == QLatin1String("sae"))
                fields << QStringLiteral("psk");
            else if (keyMgmt == QLatin1String("none"))
                fields << QStringLiteral("wep-key0");
        } else if (setting == QLatin1String("802-1x")) {
            if (eap.size() == 1 && eap.first() == QLatin1String("tls"))
                fields << QStringLiteral("private-key-password");
            else
                fields << QStringLiteral("password");
        }

        // NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION: without it,
        // only stored secrets may be returned, and this agent stores none.
        if (fields.isEmpty() || !(flags & 0x1)) {
            sendErrorReply(QStringLiteral("org.freedesktop.NetworkManager.SecretAgent.NoSecrets"),
                           QStringLiteral("No secrets"));
            return {};
        }

        setDelayedReply(true);
        const int id = m_next++;
        m_pending.insert(id, message());
        m_settings.insert(id, setting);
        m_paths.insert(id, path.path());

        emitEvent({ { "ev", "nm-secrets" }, { "id", id },
                    { "name", con.value(QStringLiteral("id")).toString() },
                    { "uuid", con.value(QStringLiteral("uuid")).toString() },
                    { "type", con.value(QStringLiteral("type")).toString() },
                    { "ssid", QString::fromUtf8(wifi.value(QStringLiteral("ssid")).toByteArray()) },
                    { "setting", setting },
                    { "keyMgmt", keyMgmt },
                    { "eap", QJsonArray::fromStringList(eap) },
                    { "identity", x.value(QStringLiteral("identity")).toString() },
                    { "fields", QJsonArray::fromStringList(fields) },
                    { "hints", QJsonArray::fromStringList(hints) },
                    // REQUEST_NEW: what was saved did not work.
                    { "again", bool(flags & 0x2) } });
        return {};
    }

    void CancelGetSecrets(const QDBusObjectPath &path, const QString &setting)
    {
        for (auto it = m_paths.begin(); it != m_paths.end();) {
            const int id = it.key();
            if (it.value() == path.path() && m_settings.value(id) == setting) {
                m_bus.send(m_pending.take(id).createErrorReply(
                    QStringLiteral("org.freedesktop.NetworkManager.SecretAgent.AgentCanceled"),
                    QStringLiteral("Canceled")));
                m_settings.remove(id);
                it = m_paths.erase(it);
                emitEvent({ { "ev", "nm-cancel" }, { "id", id } });
            } else {
                ++it;
            }
        }
    }

    // Secrets are kept by NetworkManager itself (the shell saves them into
    // the profile), so there is nothing here to save or delete.
    void SaveSecrets(const InterfaceMap &, const QDBusObjectPath &) {}
    void DeleteSecrets(const InterfaceMap &, const QDBusObjectPath &) {}

private:
    void registerAgent()
    {
        QDBusMessage m = QDBusMessage::createMethodCall(NM,
            QStringLiteral("/org/freedesktop/NetworkManager/AgentManager"),
            QStringLiteral("org.freedesktop.NetworkManager.AgentManager"),
            QStringLiteral("RegisterWithCapabilities"));
        m << QStringLiteral("org.hyprshell.agent") << uint(0);
        auto *w = new QDBusPendingCallWatcher(m_bus.asyncCall(m), this);
        connect(w, &QDBusPendingCallWatcher::finished, this, [](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<> r = *w;
            QJsonObject ev{ { "ev", "nm-agent" }, { "ok", !r.isError() } };
            if (r.isError()) {
                ev.insert(QStringLiteral("error"), r.error().name());
                ev.insert(QStringLiteral("message"), r.error().message());
            }
            emitEvent(ev);
        });
    }

    QDBusConnection m_bus;
    QMap<int, QDBusMessage> m_pending;
    QMap<int, QString> m_settings;
    QMap<int, QString> m_paths;
    int m_next = 1;
};

// ══ stdin ════════════════════════════════════════════════════════════════

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    qDBusRegisterMetaType<InterfaceMap>();
    qDBusRegisterMetaType<ManagedObjects>();

    const bool session = qEnvironmentVariable("HYPRSHELL_AGENT_BUS") == QLatin1String("session");
    QDBusConnection bus = session ? QDBusConnection::sessionBus() : QDBusConnection::systemBus();
    if (!bus.isConnected()) {
        emitEvent({ { "ev", "fatal" }, { "message", "Cannot reach the D-Bus system bus" } });
        return 1;
    }

    Bluetooth bt(bus);
    SecretAgent nm(bus);
    bt.start();
    nm.start();
    emitEvent({ { "ev", "ready" } });

    QByteArray buffer;
    QSocketNotifier in(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&in, &QSocketNotifier::activated, &app, [&] {
        char chunk[4096];
        const ssize_t n = ::read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) { app.quit(); return; }   // the shell went away
        buffer.append(chunk, int(n));
        int nl;
        while ((nl = buffer.indexOf('\n')) >= 0) {
            const QByteArray line = buffer.left(nl).trimmed();
            buffer.remove(0, nl + 1);
            if (line.isEmpty()) continue;
            const QJsonObject c = QJsonDocument::fromJson(line).object();
            const QString cmd = c.value(QStringLiteral("cmd")).toString();
            if (cmd.startsWith(QLatin1String("bt-"))) bt.command(c);
            else if (cmd.startsWith(QLatin1String("nm-"))) nm.command(c);
        }
    });

    return app.exec();
}

#include "main.moc"

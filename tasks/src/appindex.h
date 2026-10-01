#pragma once

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

// The installed applications, from their .desktop entries: what to call a
// window class or a program, and the list Startup's "Add" picks from.
class AppIndex : public QObject {
    Q_OBJECT
public:
    explicit AppIndex(QObject *parent = nullptr);

    // { id, name, icon, exec, path, comment } or empty.
    QVariantMap byClass(const QString &cls) const;
    QVariantMap byExec(const QString &program) const;
    QVariantMap byId(const QString &id) const;
    QVariantList all() const;

    void refreshIfChanged();
    static QStringList dirs();

private:
    void scan();
    QHash<QString, QVariantMap> m_byId, m_byClass, m_byExec;
    QHash<QString, QDateTime> m_stamps;
};

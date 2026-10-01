// hyprshell-cursors — turns the shell's cursor set (services/Cursor.qml
// draws it, as SVG, in the accent colour) into an installed cursor theme.
//
//   hyprshell-cursors <spec.json> <theme dir> [--preview sheet.png]
//
// Two themes in one directory, for the two ways a cursor is asked for:
//
//   hyprcursors/   Hyprland's own format: per shape a zip (.hlc) holding the
//                  SVGs and a meta.hl. Drawn from the SVG at whatever size is
//                  asked, so it is sharp at any scale. Hyprland uses it for
//                  its own cursor and for every app that asks by name through
//                  cursor-shape-v1 — most native Wayland apps.
//   cursors/       XCursor, rendered here at a set of sizes, for everything
//                  that loads a cursor theme itself: XWayland (Steam, games),
//                  GTK 3, older Qt.
//
// The spec, from the shell:
//   { "name": "Hyprshell", "sizes": [24, 32, 48, 64, 96],
//     "shapes": [ { "name": "default", "aliases": ["left_ptr", …],
//                   "hot": [0.22, 0.12], "delay": 0, "frames": ["<svg …>", …] } ] }
//
// The theme is built beside the target and swapped in whole, so nothing
// reading it ever sees half of one.

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QSvgRenderer>
#include <QTextStream>

#include <cstdio>
#include <unistd.h>

// ── a zip, stored (no compression), as hyprcursor reads one ──────────────

static quint32 crc32(const QByteArray &data)
{
    static quint32 table[256];
    static bool ready = false;
    if (!ready) {
        for (quint32 i = 0; i < 256; ++i) {
            quint32 c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = true;
    }
    quint32 c = 0xFFFFFFFFu;
    for (const char ch : data) c = table[(c ^ quint8(ch)) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void le16(QByteArray &b, quint16 v) { b.append(char(v & 0xFF)); b.append(char(v >> 8)); }
static void le32(QByteArray &b, quint32 v) { for (int i = 0; i < 4; ++i) b.append(char((v >> (8 * i)) & 0xFF)); }

static QByteArray makeZip(const QList<QPair<QString, QByteArray>> &files)
{
    QByteArray out, central;
    for (const auto &f : files) {
        const QByteArray name = f.first.toUtf8();
        const quint32 crc = crc32(f.second);
        const quint32 offset = quint32(out.size());
        le32(out, 0x04034b50); le16(out, 20); le16(out, 0); le16(out, 0);
        le16(out, 0); le16(out, 0x21);                       // 1980-01-01 00:00
        le32(out, crc); le32(out, quint32(f.second.size())); le32(out, quint32(f.second.size()));
        le16(out, quint16(name.size())); le16(out, 0);
        out.append(name);
        out.append(f.second);

        le32(central, 0x02014b50); le16(central, 20); le16(central, 20); le16(central, 0); le16(central, 0);
        le16(central, 0); le16(central, 0x21);
        le32(central, crc); le32(central, quint32(f.second.size())); le32(central, quint32(f.second.size()));
        le16(central, quint16(name.size())); le16(central, 0); le16(central, 0); le16(central, 0); le16(central, 0);
        le32(central, 0); le32(central, offset);
        central.append(name);
    }
    const quint32 cdOffset = quint32(out.size());
    out.append(central);
    le32(out, 0x06054b50); le16(out, 0); le16(out, 0);
    le16(out, quint16(files.size())); le16(out, quint16(files.size()));
    le32(out, quint32(central.size())); le32(out, cdOffset); le16(out, 0);
    return out;
}

// ── XCursor ───────────────────────────────────────────────────────────────

static QImage render(const QByteArray &svg, int size)
{
    QImage img(size, size, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    QSvgRenderer r(svg);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing);
    r.render(&p, QRectF(0, 0, size, size));
    return img;
}

struct XImage { int size; int xhot; int yhot; int delay; QImage img; };

static QByteArray makeXCursor(const QList<XImage> &images)
{
    QByteArray out;
    const quint32 ntoc = quint32(images.size());
    le32(out, 0x72756358);              // "Xcur"
    le32(out, 16); le32(out, 0x10000); le32(out, ntoc);
    quint32 pos = 16 + ntoc * 12;
    for (const auto &im : images) {
        le32(out, 0xfffd0002); le32(out, quint32(im.size)); le32(out, pos);
        pos += 36 + quint32(im.img.width() * im.img.height() * 4);
    }
    for (const auto &im : images) {
        le32(out, 36); le32(out, 0xfffd0002); le32(out, quint32(im.size)); le32(out, 1);
        le32(out, quint32(im.img.width())); le32(out, quint32(im.img.height()));
        le32(out, quint32(im.xhot)); le32(out, quint32(im.yhot)); le32(out, quint32(im.delay));
        for (int y = 0; y < im.img.height(); ++y) {
            const QRgb *line = reinterpret_cast<const QRgb *>(im.img.constScanLine(y));
            for (int x = 0; x < im.img.width(); ++x) le32(out, line[x]);   // premultiplied ARGB
        }
    }
    return out;
}

static bool writeFile(const QString &path, const QByteArray &data)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    return f.write(data) == data.size();
}

int main(int argc, char **argv)
{
    // Offscreen: this draws into images and never opens a window.
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    const QStringList args = app.arguments();
    if (args.size() < 3) {
        fprintf(stderr, "usage: hyprshell-cursors <spec.json> <theme dir> [--preview sheet.png]\n");
        return 2;
    }
    QFile specFile(args.at(1));
    if (!specFile.open(QIODevice::ReadOnly)) { fprintf(stderr, "cannot read %s\n", qPrintable(args.at(1))); return 1; }
    const QJsonObject spec = QJsonDocument::fromJson(specFile.readAll()).object();
    const QString name = spec.value("name").toString("Hyprshell");
    QList<int> sizes;
    for (const auto v : spec.value("sizes").toArray()) sizes << v.toInt();
    if (sizes.isEmpty()) sizes = { 24, 32, 48, 64, 96 };
    const QJsonArray shapes = spec.value("shapes").toArray();

    const QString target = QDir::cleanPath(args.at(2));
    const QString tmp = target + ".new";
    QDir(tmp).removeRecursively();
    if (!QDir().mkpath(tmp + "/hyprcursors") || !QDir().mkpath(tmp + "/cursors")) {
        fprintf(stderr, "cannot create %s\n", qPrintable(tmp));
        return 1;
    }

    writeFile(tmp + "/manifest.hl",
              ("name = " + name + "\ndescription = Drawn by Hyprshell in its accent colour\n"
               "version = 1\ncursors_directory = hyprcursors\n").toUtf8());
    writeFile(tmp + "/index.theme",
              ("[Icon Theme]\nName=" + name + "\nComment=Drawn by Hyprshell in its accent colour\n").toUtf8());

    QStringList written;     // names with a real XCursor file, so aliases never replace one
    for (const auto v : shapes) {
        const QJsonObject s = v.toObject();
        const QString shape = s.value("name").toString();
        const QJsonArray hot = s.value("hot").toArray();
        const double hx = hot.at(0).toDouble(), hy = hot.at(1).toDouble();
        const int delay = s.value("delay").toInt();
        QList<QByteArray> frames;
        for (const auto f : s.value("frames").toArray()) frames << f.toString().toUtf8();
        if (shape.isEmpty() || frames.isEmpty()) continue;
        QStringList aliases;
        for (const auto a : s.value("aliases").toArray()) aliases << a.toString();

        // hyprcursor
        QString meta;
        QTextStream m(&meta);
        m << "resize_algorithm = bilinear\n"
          << "hotspot_x = " << hx << "\nhotspot_y = " << hy << "\n"
          << "nominal_size = 1.0\n";
        for (const QString &a : aliases) m << "define_override = " << a << "\n";
        QList<QPair<QString, QByteArray>> files;
        for (int i = 0; i < frames.size(); ++i) {
            const QString file = QStringLiteral("%1_%2.svg").arg(shape).arg(i);
            m << "define_size = 0, " << file;
            if (frames.size() > 1 && delay > 0) m << ", " << delay;
            m << "\n";
            files.append({ file, frames.at(i) });
        }
        m.flush();
        files.prepend({ QStringLiteral("meta.hl"), meta.toUtf8() });
        writeFile(tmp + "/hyprcursors/" + shape + ".hlc", makeZip(files));

        // XCursor
        QList<XImage> images;
        for (const int size : sizes)
            for (const QByteArray &f : frames)
                images.append({ size, qRound(hx * size), qRound(hy * size),
                                frames.size() > 1 ? delay : 0, render(f, size) });
        writeFile(tmp + "/cursors/" + shape, makeXCursor(images));
        written << shape;
        for (const QString &a : aliases) {
            if (a == shape || written.contains(a) || QFile::exists(tmp + "/cursors/" + a)) continue;
            QFile::link(shape, tmp + "/cursors/" + a);
        }
    }

    // A sheet of every shape, for looking at.
    const int pi = args.indexOf("--preview");
    if (pi > 0 && pi + 1 < args.size()) {
        const int cell = 72, cols = 8;
        const int rows = int((shapes.size() + cols - 1) / cols);
        QImage sheet(cols * cell, rows * cell, QImage::Format_ARGB32_Premultiplied);
        sheet.fill(QColor(spec.value("previewBg").toString("#808080")));
        QPainter p(&sheet);
        for (int i = 0; i < shapes.size(); ++i) {
            const QJsonArray fr = shapes.at(i).toObject().value("frames").toArray();
            if (fr.isEmpty()) continue;
            p.drawImage((i % cols) * cell + 4, (i / cols) * cell + 4, render(fr.at(0).toString().toUtf8(), 64));
        }
        p.end();
        sheet.save(args.at(pi + 1));
    }

    // Swap the new theme in whole.
    const QString old = target + ".old";
    QDir(old).removeRecursively();
    if (QDir(target).exists() && !QDir().rename(target, old)) {
        fprintf(stderr, "cannot move the old theme aside\n");
        return 1;
    }
    if (!QDir().rename(tmp, target)) {
        fprintf(stderr, "cannot put the new theme in place\n");
        QDir().rename(old, target);
        return 1;
    }
    QDir(old).removeRecursively();
    printf("%s\n", qPrintable(target));
    return 0;
}

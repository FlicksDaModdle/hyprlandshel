.pragma library

// Why the computer is slow, from what Monitor sees now: a list of findings,
// worst first. Each is { level, icon, title, detail, view, key }:
//
//   level  2 slowing things down now, 1 worth knowing, 0 fine
//   view   the view that shows more ("processes", "performance"…)
//   key    a process row to select there ("p:1234")
//
// The strongest single signal is pressure stall information (PSI): the
// share of the last ten seconds in which something that wanted to run
// was waiting — for a CPU, for memory, for the disk. High utilisation
// with no waiting is a machine doing its job; waiting is what you feel.

function gb(n) { return (n / 1073741824).toFixed(n >= 10737418240 ? 0 : 1) + " GB"; }
function pc(n) { return (n < 10 ? n.toFixed(1) : Math.round(n)) + "%"; }

function findings(mon, procs) {
    var out = [];
    var cpu = mon.cpu || {}, mem = mon.memory || {}, psi = mon.pressure || {}, sys = mon.system || {};
    var info = mon.info || {};

    // ── processor ──
    var topCpu = procs.top("cpu", 1)[0];
    var cpuWait = psi.cpuSome || 0;
    if (cpuWait >= 25 || (cpu.percent || 0) >= 90) {
        out.push({ level: 2, icon: "cpu", view: "processes", key: topCpu ? "p:" + topCpu.pid : "",
                   title: "The processor is flat out (" + pc(cpu.percent || 0) + ")",
                   detail: (cpuWait > 1 ? "Programs are waiting for a CPU " + pc(cpuWait) + " of the time. " : "")
                           + (topCpu && topCpu.value > 10 ? topCpu.name + " is using " + pc(topCpu.value) + " of it." : "") });
    } else if (topCpu && topCpu.value >= 30) {
        out.push({ level: 1, icon: "cpu", view: "processes", key: "p:" + topCpu.pid,
                   title: topCpu.name + " is using " + pc(topCpu.value) + " of the processor",
                   detail: "Everything else still has room, but it is the busiest thing running." });
    }

    // ── memory ──
    var avail = mem.total > 0 ? mem.available / mem.total : 1;
    var memWait = psi.memSome || 0;
    var topMem = procs.top("mem", 1)[0];
    if (memWait >= 5 || avail < 0.08) {
        out.push({ level: 2, icon: "database", view: "performance", key: "",
                   title: "Memory is nearly full (" + gb(mem.available || 0) + " free of " + gb(mem.total || 0) + ")",
                   detail: (memWait > 0.5 ? "Programs are stalled waiting for memory " + pc(memWait) + " of the time. " : "")
                           + (topMem ? topMem.name + " holds the most, " + gb(topMem.value) + "." : "") });
    } else if (avail < 0.2) {
        out.push({ level: 1, icon: "database", view: "processes", key: topMem ? "p:" + topMem.pid : "",
                   title: "Memory is getting full: " + gb(mem.available || 0) + " left",
                   detail: topMem ? topMem.name + " holds the most, " + gb(topMem.value) + "." : "" });
    }
    if ((mem.swapUsed || 0) > 536870912 && mem.swapTotal > 0) {
        out.push({ level: (mem.swapUsed / mem.swapTotal > 0.5 || memWait > 2) ? 2 : 1, icon: "disk", view: "performance", key: "",
                   title: gb(mem.swapUsed) + " has been moved out to swap",
                   detail: "Programs whose memory was swapped out are slow to come back to — expect a pause when switching to them." });
    }

    // ── disks ──
    var ioWait = psi.ioSome || 0;
    var topDisk = procs.top("disk", 1)[0];
    var disks = mon.disks || [];
    for (var i = 0; i < disks.length; ++i) {
        var d = disks[i];
        if (d.active >= 90) {
            out.push({ level: 2, icon: "disk", view: "performance", key: "",
                       title: d.model + " is busy " + pc(d.active) + " of the time",
                       detail: "Reading " + (d.readBps / 1048576).toFixed(1) + " MB/s and writing " + (d.writeBps / 1048576).toFixed(1) + " MB/s"
                               + (d.responseMs > 20 ? ", " + Math.round(d.responseMs) + " ms a request" : "") + "."
                               + (topDisk && topDisk.value > 1048576 ? " Mostly " + topDisk.name + "." : "") });
        }
        var mounts = d.mounts || [];
        for (var m = 0; m < mounts.length; ++m) {
            var mt = mounts[m];
            // A read-only filesystem is full by design (an image, a
            // squashfs), and the boot partition is meant to be small.
            if (mt.total > 0 && mt.free / mt.total < 0.05 && mt.fs !== "vfat" && !mt.readOnly)
                out.push({ level: mt.free / mt.total < 0.02 ? 2 : 1, icon: "disk", view: "diskspace", key: "",
                           title: mt.path + " is " + pc(100 - 100 * mt.free / mt.total) + " full",
                           detail: "Only " + gb(mt.free) + " left. A nearly full disk slows everything that writes, and btrfs especially." });
        }
    }
    if (ioWait >= 15 && !out.some(function (f) { return f.icon === "disk" && f.level === 2; })) {
        out.push({ level: 2, icon: "disk", view: "processes", key: topDisk ? "p:" + topDisk.pid : "",
                   title: "Programs are waiting on the disk " + pc(ioWait) + " of the time",
                   detail: topDisk && topDisk.value > 0 ? topDisk.name + " is reading and writing the most." : "" });
    }

    // ── heat ──
    var t = cpu.temp;
    if (t !== undefined && t !== null && t >= 90) {
        var slowed = info.maxMHz > 0 && cpu.mhz > 0 && cpu.mhz < info.maxMHz * 0.6 && (cpu.percent || 0) > 50;
        out.push({ level: slowed ? 2 : 1, icon: "zap", view: "power", key: "",
                   title: "The processor is at " + Math.round(t) + " °C",
                   detail: slowed ? "Busy but running at " + (cpu.mhz / 1000).toFixed(1) + " GHz of " + (info.maxMHz / 1000).toFixed(1)
                                    + " — it is slowing itself to cool down. Check the vents and the fan profile."
                                  : "Hot, though not yet slowing down." });
    }

    // ── GPU ──
    var gpus = mon.gpus || [];
    for (var g = 0; g < gpus.length; ++g) {
        if (gpus[g].busy >= 95)
            out.push({ level: 1, icon: "monitor", view: "performance", key: "",
                       title: gpus[g].name + " is fully busy",
                       detail: "Fine for a game; for anything else, something is drawing more than it should." });
        // An integrated GPU's "dedicated" memory is a small carve-out that is
        // meant to fill and spill into shared memory; only a discrete
        // card running out is news.
        if (!gpus[g].integrated && gpus[g].vramTotal > 0 && gpus[g].vramUsed / gpus[g].vramTotal > 0.95)
            out.push({ level: 1, icon: "monitor", view: "performance", key: "",
                       title: gpus[g].name + "'s memory is full",
                       detail: "Textures spill into system memory, which is much slower." });
    }

    // ── power ──
    var profile = sys.platformProfile || "";
    if (/low-power|quiet|power-saver/.test(profile) || (sys.epp === "power" && sys.governor === "powersave")) {
        out.push({ level: (cpu.percent || 0) > 60 ? 2 : 1, icon: "zap", view: "power", key: "",
                   title: "The power profile is holding the processor back",
                   detail: "It is set to " + (profile || "power saving") + ". Switch to Balanced or Performance under Power & frequency." });
    }
    var bat = mon.battery || {};
    if (bat.present && !bat.ac && bat.percent <= 15)
        out.push({ level: 1, icon: "battery", view: "performance", key: "",
                   title: "The battery is at " + bat.percent + "%",
                   detail: "Many laptops slow down to stretch the last of it." });

    // ── load ──
    var cores = info.threads || 1;
    if ((sys.load1 || 0) > cores * 2 && !out.some(function (f) { return f.icon === "cpu" && f.level === 2; }))
        out.push({ level: 1, icon: "cpu", view: "processes", key: "",
                   title: "More is queued than the processor can run",
                   detail: "The load average is " + sys.load1.toFixed(1) + " on " + cores + " logical processors." });

    out.sort(function (a, b) { return b.level - a.level; });
    return out;
}

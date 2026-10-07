import QtQuick
import Hyprshell

// An invitation: what, when, where, who asked, and the answer — sent to
// the organiser, and the event kept for the calendar.
Rectangle {
    id: inv
    property var body
    readonly property var ev: inv.body ? inv.body.invite : null
    property string answered: ""
    readonly property string mine: {
        if (inv.answered) return inv.answered;
        if (inv.body.inviteResponse) return inv.body.inviteResponse;
        const me = ((Mail.accountById(inv.body.summary.account) || {}).email || "").toLowerCase();
        const a = (inv.ev.attendees || []).find(x => x.email.toLowerCase() === me);
        return a && a.status !== "NEEDS-ACTION" ? a.status : "";
    }
    readonly property bool cancelled: inv.ev && (inv.ev.method === "CANCEL" || inv.ev.status === "CANCELLED")
    height: col.implicitHeight + 28
    radius: Appearance.rSm
    color: Appearance.hover
    border.width: 1
    border.color: Appearance.rule

    function when() {
        const s = new Date(inv.ev.start * 1000), e = new Date(inv.ev.end * 1000);
        if (inv.ev.allDay) return Qt.formatDate(s, "dddd d MMMM yyyy") + " · all day";
        const sameDay = s.toDateString() === e.toDateString();
        return Qt.formatDateTime(s, "dddd d MMMM yyyy, hh:mm") + " – " + (sameDay ? Qt.formatTime(e, "hh:mm") : Qt.formatDateTime(e, "d MMM hh:mm"))
            + (inv.ev.tzid ? "  (" + inv.ev.tzid + ")" : "");
    }
    function answer(r) {
        Mail.call("invite.respond", { id: inv.body.id, response: r }, (ok, res) => {
            if (ok) { inv.answered = res.response; Mail.toast(r === "decline" ? "Declined — the organiser has been told" : "Answer sent — it's in your calendar", false, "", null); }
        });
    }

    Row {
        x: 14; y: 14
        spacing: 14
        Rectangle {
            width: 52; height: 56
            radius: Appearance.rSm
            color: Appearance.accent
            Column {
                anchors.centerIn: parent
                StyledText { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(new Date(inv.ev.start * 1000), "MMM").toUpperCase(); font.pixelSize: Appearance.fs(10.5); font.weight: Font.DemiBold; color: Appearance.inkOnAccent }
                StyledText { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDate(new Date(inv.ev.start * 1000), "d"); font.pixelSize: Appearance.fs(20); font.weight: Font.Bold; color: Appearance.inkOnAccent }
            }
        }
        Column {
            id: col
            width: inv.width - 52 - 14 - 28
            spacing: 4
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: (inv.cancelled ? "Cancelled: " : "") + (inv.ev.summary || "Invitation")
                font.pixelSize: Appearance.fs(14)
                font.weight: Font.DemiBold
                font.strikeout: inv.cancelled
            }
            StyledText { width: parent.width; wrapMode: Text.WordWrap; text: inv.when(); font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
            StyledText { visible: inv.ev.location !== ""; width: parent.width; wrapMode: Text.WordWrap; text: inv.ev.location; font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
            StyledText {
                visible: !!inv.ev.organizer
                text: inv.ev.organizer ? "From " + (inv.ev.organizer.name || inv.ev.organizer.email) + " · " + (inv.ev.attendees || []).length + " invited" : ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
            Item { width: 1; height: 6 }
            Row {
                visible: !inv.cancelled && inv.ev.method !== "REPLY"
                spacing: 8
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: inv.mine === "ACCEPTED" ? "You're going." : inv.mine === "TENTATIVE" ? "You might go." : inv.mine === "DECLINED" ? "You declined." : "Going?"
                    font.pixelSize: Appearance.fs(12.5)
                    font.weight: Font.DemiBold
                    rightPadding: 6
                }
                DialogButton { text: "Yes"; primary: inv.mine === "ACCEPTED"; onTriggered: inv.answer("accept") }
                DialogButton { text: "Maybe"; primary: inv.mine === "TENTATIVE"; onTriggered: inv.answer("tentative") }
                DialogButton { text: "No"; primary: inv.mine === "DECLINED"; onTriggered: inv.answer("decline") }
            }
        }
    }
}

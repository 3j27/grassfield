import QtQuick
import QtTest
import "../../packaging/sddm/theme/Strings.js" as Strings

// The login theme's pure rules (ADR-0042; packaging/sddm/theme/Strings.js): the account picture only from a folder root
// writes (opus review of c5b02369: a user's ~/.face.icon could be a FIFO that blocks the greeter for every user), the
// session selected first, the initials and the two languages.
TestCase {
    name: "LoginStrings"

    function test_pictureOnlyFromRootFolders() {
        compare(Strings.pictureUrl("/var/lib/AccountsService/icons/ada"), "file:///var/lib/AccountsService/icons/ada");
        compare(Strings.pictureUrl("/usr/share/sddm/faces/ada.face.icon"), "file:///usr/share/sddm/faces/ada.face.icon");
        const refused = [
            "", null, undefined,
            "/home/ada/.face.icon", "/home/ada/.face", "~/.face.icon",
            "/usr/share/sddm/faces/.face.icon", // SDDM's generic face: the initials
            "/var/lib/AccountsService/icons/../../../home/ada/.face.icon",
            "/var/lib/AccountsService/icons/sub/ada", "/var/lib/AccountsService/icons/.hidden",
            "/var/lib/AccountsService/icons/", "/usr/share/sddm/faces/ada.png",
            "/usr/share/sddm/faces/../../../../home/ada/x.face.icon",
            "/tmp/var/lib/AccountsService/icons/ada", "file:///var/lib/AccountsService/icons/ada",
            "/var/lib/AccountsService/icons/ada\n/etc/shadow"
        ];
        for (let i = 0; i < refused.length; i++)
            compare(Strings.pictureUrl(refused[i]), "", "refused: " + JSON.stringify(refused[i]));
    }

    function test_sessionSelectedFirst() {
        compare(Strings.pickSession(["Hyprland", "Omarchy (Hyprland uwsm)", "Grassfield (uwsm)"], 0), 2);
        compare(Strings.pickSession(["Hyprland", "Omarchy (Hyprland uwsm)"], 0), 1);
        compare(Strings.pickSession(["Plasma", "Hyprland"], 1), 1);
        compare(Strings.pickSession(["Plasma", "Hyprland"], 7), 0);
        compare(Strings.pickSession([], 0), -1);
    }

    function test_initialsAndWords() {
        compare(Strings.initials("Ada Lovelace"), "AL");
        compare(Strings.initials("  guest "), "G");
        compare(Strings.initials(""), "");
        compare(Strings.text("incorrect", "fr_FR"), "Mot de passe incorrect");
        compare(Strings.text("incorrect", "en_US"), "Incorrect password");
        compare(Strings.text("nothing", "fr_FR"), "");
    }
}

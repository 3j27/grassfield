import QtQuick
import QtTest

// GF-103: what the UI relies on to show numbers and sizes in the UI language.
TestCase {
    name: "LocaleFormat"

    function test_frDecimalComma() {
        compare(Qt.locale("fr_FR").toString(15.5, "f", 1), "15,5");
        compare(Qt.locale("en_US").toString(15.5, "f", 1), "15.5");
        compare(Qt.locale("fr_FR").toString(1.25, "f", 2), "1,25");
    }

    function test_dataSizeUsesLocale() {
        verify(Qt.locale("fr_FR").formattedDataSize(15500000000, 1, Locale.DataSizeSIFormat).indexOf("15,5") === 0);
        verify(Qt.locale("en_US").formattedDataSize(15500000000, 1, Locale.DataSizeSIFormat).indexOf("15.5") === 0);
    }
}

import QtQuick
import QtTest
import "../../shell/search/Units.js" as Units

TestCase {
    name: "SearchUnits"

    function test_length() {
        const r = Units.answer("10 km in mi");
        verify(r !== null);
        fuzzyCompare(r.value, 6.2137119, 1e-6);
        compare(r.text, "6.2137 mi");
        compare(Units.answer("1 mile to km").text, "1.6093 km");
        compare(Units.answer("12 in to cm").text, "30.48 cm");
        compare(Units.answer("3 feet in inches").text, "36 in");
    }

    function test_mass() {
        compare(Units.answer("1 kg to lb").text, "2.2046 lb");
        compare(Units.answer("500 g in oz").text, "17.637 oz");
    }

    function test_temperature() {
        compare(Units.answer("100f to c").text, "37.7778 C");
        compare(Units.answer("0 c to f").text, "32 F");
        compare(Units.answer("0 C in K").text, "273.15 K");
        compare(Units.answer("-40 f to c").text, "-40 C");
    }

    function test_dataSizes() {
        compare(Units.answer("2 GiB in MB").text, "2147.4836 MB");
        compare(Units.answer("1 TB to GB").text, "1000 GB");
        compare(Units.answer("1024 mib to gib").text, "1 GiB");
        compare(Units.answer("1 KiB in B").text, "1024 B");
    }

    function test_rejections() {
        compare(Units.answer("10 km in kg"), null);
        compare(Units.answer("10 km in xyz"), null);
        compare(Units.answer("10 km"), null);
        compare(Units.answer("km in mi"), null);
        compare(Units.answer("10 constructor in mi"), null);
        compare(Units.answer("10 km in __proto__"), null);
        compare(Units.answer("10 km in toString"), null);
        compare(Units.answer("x".repeat(500)), null);
        compare(Units.answer("5 usd in eur"), null);
    }

    // Capture defect 5: conversions in the session's language (Spotlight in French).
    readonly property var fr: Qt.locale("fr_FR")
    readonly property var en: Qt.locale("en_US")

    function test_qtLocaleCarriesWhatTheFormatNeeds() {
        compare(fr.decimalPoint, ",");
        verify(fr.groupSeparator !== "" && fr.groupSeparator !== ",");
        compare(en.decimalPoint, ".");
        compare(en.groupSeparator, ",");
    }

    function test_frenchConnectors() {
        compare(Units.answer("25 km en mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km vers mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km in mi", fr).text, "15,5343 mi", "the English words keep working in French");
        compare(Units.answer("25 km to mi", fr).text, "15,5343 mi");
        compare(Units.answer("25 km en mi"), null, "en is a French word only");
        compare(Units.answer("25 km en mi", en), null);
        compare(Units.answer("25 km vers mi", en), null);
    }

    function test_decimalComma() {
        fuzzyCompare(Units.answer("2,5 km en m", fr).value, 2500, 1e-9);
        compare(Units.answer("2,5 km en m", fr).text, "2" + fr.groupSeparator + "500 m");
        fuzzyCompare(Units.answer("2.5 km en m", fr).value, 2500, 1e-9);
        fuzzyCompare(Units.answer("0,5 kg en g", fr).value, 500, 1e-9);
        fuzzyCompare(Units.answer("-3,5 c en f", fr).value, 25.7, 1e-9);
        // English: the comma groups thousands, and a lone comma is read as a decimal point.
        fuzzyCompare(Units.answer("1,000 m in km", en).value, 1, 1e-9);
        fuzzyCompare(Units.answer("2,5 km in m", en).value, 2500, 1e-9);
    }

    function test_groupedNumbersAreRead() {
        fuzzyCompare(Units.answer("1 000 m en km", fr).value, 1, 1e-9);
        fuzzyCompare(Units.answer("1" + fr.groupSeparator + "000 m en km", fr).value, 1, 1e-9);
        fuzzyCompare(Units.answer("12 000 000 m en km", fr).value, 12000, 1e-9);
    }

    function test_resultsAreLocalizedAndRounded() {
        const g = fr.groupSeparator;
        compare(Units.answer("25 km in mi", en).text, "15.5343 mi");
        compare(Units.answer("1 TB to B", en).text, "1,000,000,000,000 B");
        compare(Units.answer("1 TB to B", fr).text, "1" + g + "000" + g + "000" + g + "000" + g + "000 B");
        compare(Units.answer("123456 mm en km", fr).text, "0,1235 km");
        compare(Units.answer("2147,483648 mo en go", fr).text, "2,1475 GB");
        compare(Units.answer("1 km en m", fr).text, "1" + g + "000 m");
        compare(Units.answer("0 c en k", fr).text, "273,15 K");
        compare(Units.answer("100 f en c", fr).text, "37,7778 C");
        compare(Units.answer("1 mm en m", fr).text, "0,001 m");
        compare(Units.answer("3 mm en km", fr).text, "0,000003 km");
        // The value stays exact; only the text rounds.
        fuzzyCompare(Units.answer("25 km en mi", fr).value, 15.534279, 1e-6);
    }

    function test_frenchUnitNames() {
        const g = fr.groupSeparator;
        compare(Units.answer("25 kilomètres en miles", fr).to, "mi");
        compare(Units.answer("10 pouces en centimètres", fr).text, "25,4 cm");
        compare(Units.answer("3 pieds en pouces", fr).text, "36 in");
        compare(Units.answer("2 livres en kilogrammes", fr).text, "0,9072 kg");
        compare(Units.answer("500 grammes en onces", fr).text, "17,637 oz");
        compare(Units.answer("2 Go en Mo", fr).text, "2" + g + "000 MB");
        compare(Units.answer("1 Kio en o", fr).text, "1" + g + "024 B");
        compare(Units.answer("10 km en kg", fr), null);
    }

    function test_noGroupingWithoutALocale() {
        compare(Units.answer("1 km in m").text, "1000 m");
    }
}

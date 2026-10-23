import QtQuick
import QtTest
import "../../shell/search/Units.js" as Units

TestCase {
    name: "SearchUnits"

    function test_length() {
        const r = Units.answer("10 km in mi");
        verify(r !== null);
        fuzzyCompare(r.value, 6.2137119, 1e-6);
        compare(r.text, "6.2137119 mi");
        compare(Units.answer("1 mile to km").text, "1.609344 km");
        compare(Units.answer("12 in to cm").text, "30.48 cm");
        compare(Units.answer("3 feet in inches").text, "36 in");
    }

    function test_mass() {
        compare(Units.answer("1 kg to lb").text, "2.2046226 lb");
        compare(Units.answer("500 g in oz").text, "17.636981 oz");
    }

    function test_temperature() {
        compare(Units.answer("100f to c").text, "37.777778 C");
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
}

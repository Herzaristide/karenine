import QtQuick
import QtTest
import "pure"  // monté par tests/run.sh

// La source « web » (services/WebSource.qml) : des liens fabriqués, aucune
// requête réseau.
TestCase {
    name: "WebSource"

    WebSource { id: web }

    SignalSpy {
        id: spy
        target: web
        signalName: "produced"
    }

    function init() {
        spy.clear();
    }

    function produced(q) {
        web.search(q, 7);
        compare(spy.count, 1);
        compare(spy.signalArguments[0][0], 7, "le numéro de requête revient tel quel");
        return spy.signalArguments[0][1];
    }

    function test_recognises_addresses() {
        compare(web._asUrl("https://nixos.org/manual"), "https://nixos.org/manual");
        compare(web._asUrl("HTTP://x.org"), "HTTP://x.org");
        compare(web._asUrl("nixos.org"), "https://nixos.org");
        compare(web._asUrl("  wiki.nixos.org/wiki/Flakes "), "https://wiki.nixos.org/wiki/Flakes");
        compare(web._asUrl("my-site.co.uk"), "https://my-site.co.uk");
    }

    function test_plain_words_are_not_addresses() {
        compare(web._asUrl("firefox"), "");
        compare(web._asUrl("hello world.com"), "");
        compare(web._asUrl("version 1.2"), "");
        compare(web._asUrl("ftp://x.org"), "");
    }

    function test_empty_query_gives_nothing() {
        compare(produced("   ").length, 0);
    }

    function test_search_link_is_encoded() {
        var items = produced("c++ & qml");
        compare(items.length, 1);
        compare(items[0].id, "web:web");
        compare(items[0].title, "c++ & qml");
        compare(items[0].payload.url, "https://www.google.com/search?q=c%2B%2B%20%26%20qml");
        verify(items[0].score < 100, "le web reste sous les résultats locaux");
    }

    function test_address_comes_first() {
        var items = produced("nixos.org");
        compare(items.length, 2);
        compare(items[0].id, "web:direct");
        compare(items[0].payload.url, "https://nixos.org");
        verify(items[0].score > items[1].score);
    }

    function test_limit_is_respected() {
        verify(produced("nixos.org").length <= web.limit);
    }
}

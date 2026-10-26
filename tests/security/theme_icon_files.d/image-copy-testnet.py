# Test stand-in for shell/services/image-copy.py (tests/security/theme_icon_files.sh, part 6; never shipped): it loads
# the REAL helper named by GF_REAL_HELPER and changes only name resolution and, for one test name, the address rule, so
# that its fetches reach the local HTTPS server and nothing else (no network in tests):
#   art.test      -> 127.0.0.1, allowed (the local server; the system resolver does not know the name, so a fetch that
#                    works shows that curl connected to the address the helper checked: --resolve)
#   loop.test     -> 127.0.0.1, refused by the real rule (loopback)
#   private.test  -> 10.0.0.7, refused by the real rule (private)
#   mapped.test   -> ::ffff:127.0.0.1, refused by the real rule (IPv4-mapped loopback)
#   GF_TEST_PIN="<name>=<address>" (the leak cases): <name> -> <address>, allowed for that name only;
#   any other name resolves to nothing.
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("imagecopy", os.environ["GF_REAL_HELPER"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NAMES = {"art.test": ["127.0.0.1"], "loop.test": ["127.0.0.1"], "private.test": ["10.0.0.7"], "mapped.test": ["::ffff:127.0.0.1"]}
ALLOWED = {("art.test", "127.0.0.1")}
pin = os.environ.get("GF_TEST_PIN", "")
if "=" in pin:
    name, address = pin.split("=", 1)
    NAMES[name] = [address]
    ALLOWED.add((name, address))
real_allowed = helper.address_allowed
helper.resolve_host = lambda host, port: list(NAMES.get(host, []))
helper.address_allowed = lambda host, ip: (host, ip) in ALLOWED or real_allowed(host, ip)
# GF_ART_TRACE: one line per curl call and per fetch with its outcome, so that a run in which the shell's fetches never
# reach the server says where they stopped (diagnostics only; the decisions are the real helper's).
trace = os.environ.get("GF_ART_TRACE", "")
if trace:
    def note(line):
        try:
            with open(trace, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass
    real_curl, real_fetch = helper.curl_once, helper.fetch

    def traced_curl(url, host, port, addresses, seconds):
        answer = real_curl(url, host, port, addresses, seconds)
        note("curl %s at %s within %.1fs -> %s" % (url, ",".join(addresses), seconds, "none" if answer is None else answer[0]))
        return answer

    def traced_fetch(url):
        data = real_fetch(url)
        note("fetch %s -> %s" % (url, "none" if data is None else "%d bytes" % len(data)))
        return data
    helper.curl_once, helper.fetch = traced_curl, traced_fetch
    note("start python %s pid %d" % (sys.version.split()[0], os.getpid()))
sys.exit(helper.main(sys.argv))

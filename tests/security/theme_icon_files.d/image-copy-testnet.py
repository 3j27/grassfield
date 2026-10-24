# Test stand-in for shell/services/image-copy.py (tests/security/theme_icon_files.sh, part 6; never shipped): it loads
# the REAL helper named by GF_REAL_HELPER and changes only name resolution and, for one test name, the address rule, so
# that its fetches reach the local HTTPS server and nothing else (no network in tests):
#   art.test      -> 127.0.0.1, allowed (the local server; the system resolver does not know the name, so a fetch that
#                    works shows that curl connected to the address the helper checked: --resolve)
#   loop.test     -> 127.0.0.1, refused by the real rule (loopback)
#   private.test  -> 10.0.0.7, refused by the real rule (private)
#   mapped.test   -> ::ffff:127.0.0.1, refused by the real rule (IPv4-mapped loopback)
#   any other name resolves to nothing.
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("imagecopy", os.environ["GF_REAL_HELPER"])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
NAMES = {"art.test": ["127.0.0.1"], "loop.test": ["127.0.0.1"], "private.test": ["10.0.0.7"], "mapped.test": ["::ffff:127.0.0.1"]}
real_allowed = helper.address_allowed
helper.resolve_host = lambda host, port: list(NAMES.get(host, []))
helper.address_allowed = lambda host, ip: (host == "art.test" and ip == "127.0.0.1") or real_allowed(host, ip)
sys.exit(helper.main(sys.argv))

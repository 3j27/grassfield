#!/usr/bin/env python3
"""A deterministic mutator for the fuzz harnesses of the helpers (ADR-0041 step 5, T-1). Standard library only.

  from mutate import Mutator
  m = Mutator(seed); out = m.mutate(data: bytes, corpus: list[bytes], max_len)     # 1 to 4 random operations
  python3 -I tests/fuzz/mutate.py --selftest                                         # the mutator's own properties

Operations, chosen at random with the seed: a bit flip, a special byte (NUL, 0xFF, quotes, braces, separators), a token
from the dictionary (JSON tokens, number extremes, escapes, invalid UTF-8, the keys the readers look for), a deleted,
duplicated or swapped slice, a truncation, a number replaced by an extreme, nesting, a splice of another corpus entry,
growth by repetition up to the length cap, raw random bytes. The same seed gives the same sequence, so a finding
reproduces from the seed and the iteration printed by the harness.
"""
import sys

DICTIONARY = [
    b"{", b"}", b"[", b"]", b'"', b"\\", b":", b",", b" ", b"\n", b"\t", b"null", b"true", b"false", b"-0", b"0", b"1",
    b"-1", b"1e999", b"-1e999", b"NaN", b"Infinity", b"0x", b"0xffffffffffffffff", b"2147483648", b"4294967296",
    b"18446744073709551616", b"99999999999999999999999", b"0.1", b".5", b"5.", b"1e", b"\\u0000", b"\\ud800", b"\\udfff",
    b"\\n", b'\\"', b"\\/", "é".encode(), "😀".encode(), b"\xc0\xaf", b"\xed\xa0\x80", b"\xff", b"\x80", b"\x00",
    b"address", b"class", b"title", b"pid", b"solitaryBlockedBy", b"LOCK", b"[Desktop Entry]", b"Name=", b"Exec=",
    b"TryExec=", b"StartupWMClass=", b"Type=Application", b"Hidden=true", b"NoDisplay=true", b"%f", b"%U", b"env ",
    b"COREDUMP_", b"_SYSTEMD_UNIT", b"systemd-coredump@", b"app-", b".scope", b"flatpak-", b"\\x2d", b"populated 0",
    b"populated 1", b"Discharging", b"Charging", b"..", b"../", b"/", b"//", b" - ", b"(unknown)", b"wayland-", b"hypr/",
]
EXTREMES = [b"-0", b"0", b"1e999", b"-1e999", b"NaN", b"2147483648", b"-2147483649", b"4294967296", b"18446744073709551616",
            b"1e-999", b"0.5", b"-5", b"1e", b"1.", b".1", b"99999999999999999999", b"0" * 64]
SPECIALS = bytes([0x00, 0xFF, 0x80, 0x22, 0x5C, 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A, 0x0A, 0x20, 0x2D, 0x30, 0x39, 0x65, 0x2E, 0x2F])


class Rng:
    """xorshift64*: the same arithmetic as the C++ harness, so a seed means the same thing in both."""

    MASK = (1 << 64) - 1

    def __init__(self, seed):
        self.s = ((seed * 0x9E3779B97F4A7C15) + 0x2545F4914F6CDD1D) & self.MASK or 1

    def next(self):
        s = self.s
        s ^= s >> 12
        s = (s ^ (s << 25)) & self.MASK
        s ^= s >> 27
        self.s = s
        return (s * 0x2545F4914F6CDD1D) & self.MASK

    def below(self, n):
        return 0 if n <= 0 else self.next() % n

    def coin(self):
        return self.next() & 1 == 1

    def pick(self, seq):
        return seq[self.below(len(seq))]


class Mutator:
    def __init__(self, seed):
        self.rng = Rng(seed)

    def mutate(self, data, corpus=(), max_len=65536):
        s = bytearray(data)
        for _ in range(1 + self.rng.below(4)):
            op = self.rng.below(12)
            if op == 0:
                self._flip(s)
            elif op == 1:
                self._special(s)
            elif op == 2:
                self._insert(s, self.rng.pick(DICTIONARY))
            elif op == 3:
                self._delete(s)
            elif op == 4:
                self._duplicate(s)
            elif op == 5:
                self._truncate(s)
            elif op == 6:
                self._number(s)
            elif op == 7:
                self._insert(s, (b"[" if self.rng.coin() else b"{") * (1 + self.rng.below(64)))
            elif op == 8:
                self._splice(s, corpus)
            elif op == 9:
                self._grow(s, max_len)
            elif op == 10:
                self._insert(s, bytes(self.rng.below(256) for _ in range(1 + self.rng.below(8))))
            else:
                self._swap(s)
            del s[max_len:]
        return bytes(s)

    def text(self, data, corpus=(), max_len=65536):
        """The same, for str input and output (invalid bytes replaced on the way back)."""
        return self.mutate(data.encode("utf-8", "surrogateescape"), [c.encode("utf-8", "surrogateescape") for c in corpus], max_len).decode("utf-8", "replace")

    def _pos(self, s):
        return self.rng.below(len(s) + 1)

    def _flip(self, s):
        if s:
            i = self.rng.below(len(s))
            s[i] ^= 1 << self.rng.below(8)

    def _special(self, s):
        if s:
            s[self.rng.below(len(s))] = self.rng.pick(SPECIALS)

    def _insert(self, s, token):
        p = self._pos(s)
        s[p:p] = token

    def _delete(self, s):
        if s:
            a = self.rng.below(len(s))
            del s[a:a + 1 + self.rng.below(min(16, len(s) - a))]

    def _duplicate(self, s):
        if s:
            a = self.rng.below(len(s))
            chunk = bytes(s[a:a + 1 + self.rng.below(min(32, len(s) - a))])
            self._insert(s, chunk)

    def _truncate(self, s):
        if s:
            del s[self.rng.below(len(s)):]

    def _number(self, s):
        i = 0
        while i < len(s) and not 48 <= s[i] <= 57:
            i += 1
        if i == len(s):
            return
        j = i
        while j < len(s) and (48 <= s[j] <= 57 or s[j] in b".e-+"):
            j += 1
        s[i:j] = self.rng.pick(EXTREMES)

    def _splice(self, s, corpus):
        if corpus:
            other = self.rng.pick(list(corpus))
            if other:
                a = self.rng.below(len(other))
                self._insert(s, bytes(other[a:a + 1 + self.rng.below(len(other) - a)]))

    def _grow(self, s, max_len):
        if s:
            target = min(max_len, len(s) * (2 + self.rng.below(8)) + 1)
            a = self.rng.below(len(s))
            chunk = bytes(s[a:a + 1 + self.rng.below(min(64, len(s) - a))])
            while len(s) < target:
                self._insert(s, chunk)

    def _swap(self, s):
        if len(s) >= 4:
            a, b = self.rng.below(len(s) // 2), len(s) // 2 + self.rng.below(len(s) // 2)
            s[a], s[b] = s[b], s[a]


def selftest():
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("PASS: " if cond else "FAIL: ") + what)
        ok = ok and cond

    base = b'{"on":true,"durationMs":350,"windows":[{"address":"0x55d0","x":1,"y":2,"w":3,"h":4}]}'
    a = [Mutator(7).mutate(base, [base], 4096) for _ in range(50)]
    b = [Mutator(7).mutate(base, [base], 4096) for _ in range(50)]
    check(a == b, "the same seed gives the same 50 mutations")
    check(Mutator(8).mutate(base, [base], 4096) != a[0], "another seed gives another mutation")
    check(sum(1 for x in a if x != base) >= 45, "most mutations change the input (%d of 50)" % sum(1 for x in a if x != base))
    check(all(len(x) <= 4096 for x in a), "every mutation respects the length cap")
    m = Mutator(3)
    grown = [m.mutate(base, [base], 300) for _ in range(400)]
    check(max(len(x) for x in grown) == 300, "growth reaches the cap exactly (never beyond)")
    check(any(b"\x00" in x for x in grown) and any(b"1e999" in x for x in grown), "NUL bytes and number extremes appear")
    check(Mutator(1).text("abc é", ["abc é"], 64) is not None, "text mutation returns a string")
    check(min(len(x) for x in grown) == 0 or any(len(x) < 10 for x in grown), "truncation makes short inputs")
    print("mutate selftest: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    print(__doc__)
    sys.exit(2)

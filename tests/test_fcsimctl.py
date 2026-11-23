#!/usr/bin/python3
"""Unit tests for the pure parts of tools/fcsimctl; no kernel, no root.

    python3 -m unittest tests/test_fcsimctl.py     (make check runs it)
"""
import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

TOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_loader = importlib.machinery.SourceFileLoader("fcsimctl", os.path.join(TOP, "tools", "fcsimctl"))
_spec = importlib.util.spec_from_loader("fcsimctl", _loader)
fc = importlib.util.module_from_spec(_spec)
_loader.exec_module(fc)

T1 = "21:00:00:00:00:00:00:01"
I1 = "10:00:00:00:c9:00:00:01"


class Wwn(unittest.TestCase):
    def test_spellings(self):
        for s in ("10:00:00:00:C9:00:00:01", "naa.10000000c9000001", "0x10000000c9000001",
                  "10000000c9000001", " 10:00:00:00:c9:00:00:01\n"):
            self.assertEqual(fc.wwn(s), I1, s)

    def test_invalid(self):
        for s in ("", "12:34", "00:00:00:00:00:00:00:00", "10:00:00:00:c9:00:00:0g",
                  "10000000c900000101", "naa.1000-0000-c900-0001"):
            with self.assertRaises(fc.Error, msg=s):
                fc.wwn(s)

    def test_rule_name(self):
        self.assertEqual(fc.rule_name("any"), "any")
        self.assertEqual(fc.rule_name("naa.21000000" "00000001"), T1)


class FaultCheck(unittest.TestCase):
    def test_normalized(self):
        self.assertEqual(fc.fault_check({"delay_ms": "0x10", "drop": " rsp ", "count": "-1"}),
                         {"delay_ms": "16", "drop": "rsp", "count": "-1"})

    def test_refused(self):
        for attrs in ({"delay": "1"}, {"drop": "all"}, {"error": "eio"},
                      {"probability": "101"}, {"count": "-2"}, {"delay_ms": "1e3"},
                      {"delay_ms": str(3600 * 1000 + 1)}):
            with self.assertRaises(fc.Error, msg=attrs):
                fc.fault_check(attrs)


class ZoneName(unittest.TestCase):
    def test(self):
        for n in ("z1", "a-b_c.d", "!~"):
            self.assertEqual(fc.zone_name_check(n), n)
        for n in ("", "a b", "a,b", "a/b", ".", "..", "é", 1):
            with self.assertRaises(fc.Error, msg=repr(n)):
                fc.zone_name_check(n)


class RestorePlan(unittest.TestCase):
    def cfg(self, **kw):
        c = {"version": 1,
             "zoning": {"mode": "on", "zones": {"z1": [I1, T1, I1.upper()]}},
             "hosts": [{"wwpn": I1, "link": "down",
                        "faults": [{"target": "any", "delay_ms": 5, "count": 2}]}]}
        c.update(kw)
        return c

    def test_normalized(self):
        p = fc.restore_plan(self.cfg())
        self.assertEqual(p["mode"], "on")
        self.assertEqual(p["zones"], {"z1": [I1, T1]})		# duplicates dropped
        self.assertEqual(p["hosts"], [{"wwpn": I1, "wwnn": None, "link": "down",
                                       "faults": [("any", {"delay_ms": "5", "count": "2"})]}])

    def test_unknown_keys(self):
        bad = [self.cfg(extra=1),
               self.cfg(zoning={"mode": "off", "zone": {}}),
               self.cfg(hosts=[{"wwpn": I1, "lnk": "up"}]),
               self.cfg(hosts=[{"wwpn": I1, "faults": [{"target": T1, "delay": 1}]}])]
        for c in bad:
            with self.assertRaisesRegex(fc.Error, "unknown key", msg=c):
                fc.restore_plan(c)

    def test_refused(self):
        bad = [self.cfg(version=2),
               self.cfg(zoning={"mode": "maybe"}),
               self.cfg(hosts=[{"wwpn": I1}, {"wwpn": I1.upper()}]),
               self.cfg(hosts=[{"wwpn": I1, "link": "sideways"}]),
               self.cfg(hosts=[{"wwpn": I1, "faults": [{"target": T1}, {"target": T1}]}]),
               self.cfg(zoning={"zones": {"z": ["10:00:00:00:00:00:%02x:%02x" % (i // 256, i % 256)
                                                for i in range(1, fc.ZONE_MAX_MEMBERS + 2)]}}),
               self.cfg(hosts="none")]
        for c in bad:
            with self.assertRaises(fc.Error, msg=c):
                fc.restore_plan(c)


class FaultSet(unittest.TestCase):
    """fault_set on a plain directory standing in for configfs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.h = self.tmp.name
        os.mkdir(os.path.join(self.h, "faults"))

    def tearDown(self):
        self.tmp.cleanup()

    def attrs(self, t):
        d = os.path.join(self.h, "faults", t)
        return {k: fc.read(os.path.join(d, k)) for k in os.listdir(d)}

    def test_create_and_update(self):
        fc.fault_set(self.h, T1, {"delay_ms": "5", "count": "3"})
        self.assertEqual(self.attrs(T1), {"delay_ms": "5", "count": "3"})
        # An update without count keeps what is left of it.
        with open(os.path.join(self.h, "faults", T1, "count"), "w") as f:
            f.write("1")		# two commands caught meanwhile
        for k in fc.FAULT_ATTRS:	# the kernel shows every attribute
            p = os.path.join(self.h, "faults", T1, k)
            if not os.path.exists(p):
                with open(p, "w") as f:
                    f.write(fc.FAULT_DEFAULTS[k])
        fc.fault_set(self.h, T1, {"drop": "rsp"})
        a = self.attrs(T1)
        self.assertEqual((a["drop"], a["delay_ms"], a["count"]), ("rsp", "5", "1"))

    def test_bad_attribute_creates_nothing(self):
        with self.assertRaises(fc.Error):
            fc.fault_set(self.h, T1, {"drop": "everything"})
        self.assertFalse(os.path.exists(os.path.join(self.h, "faults", T1)))


if __name__ == "__main__":
    unittest.main()

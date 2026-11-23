#!/usr/bin/python3
"""Print FC transport netlink events (fc_host_post_event) for a while.

    fc-events.py <seconds>

The first line is "listening" once the socket is bound: events posted after
it are caught (start_events in tests/lib.sh waits for it).  Then each line:
"host<N> <event name> 0x<event data>".  A LINK_FPIN event also carries the
ELS payload, which follows decoded, e.g.
"... li type=2 detecting=<wwpn> attached=<wwpn> threshold=1000 count=5
pnames=<wwpn>[,<wwpn>...]".
"""
import socket
import struct
import sys
import time

NETLINK_SCSITRANSPORT = 18
# The kernel passes SCSI_NL_GRP_FC_EVENTS (1 << 2) to nlmsg_multicast() as a
# group *number*, so the bind() bitmask is 1 << (4 - 1).
SCSI_NL_GRP_FC_EVENTS = 1 << 2
GROUP_MASK = 1 << (SCSI_NL_GRP_FC_EVENTS - 1)

# include/scsi/scsi_transport_fc.h: enum fc_host_event_code
EVENTS = {
    0x1: "LIP", 0x2: "LINKUP", 0x3: "LINKDOWN", 0x4: "LIPRESET", 0x5: "RSCN",
    0x103: "ADAPTER_CHANGE", 0x200: "PORT_UNKNOWN", 0x201: "PORT_OFFLINE",
    0x202: "PORT_ONLINE", 0x204: "PORT_FABRIC", 0x500: "LINK_UNKNOWN",
    0x501: "LINK_FPIN", 0xFFFF: "VENDOR_UNIQUE",
}

# nlmsghdr (16) + scsi_nl_hdr (8) + struct fc_nl_event
FC_NL_EVENT = struct.Struct("=QQHHIII")
OFFSET = 16 + 8
DATA = OFFSET + FC_NL_EVENT.size - 4	# event_data is the payload's start
FCH_EVT_LINK_FPIN = 0x501

# include/uapi/scsi/fc/fc_els.h: struct fc_els_fpin and its descriptors
ELS_FPIN = 0x16
DTAG_LI, DTAG_DN, DTAG_PN, DTAG_CN = 0x00020001, 0x00020002, 0x00020003, 0x00020004


def wwpn(v):
    return ":".join("%02x" % b for b in v.to_bytes(8, "big"))


def decode_fpin(p):
    """The ELS FPIN payload (one descriptor, as fcsim sends) as text."""
    cmd, dlen = struct.unpack_from(">B3xI", p, 0)
    if cmd != ELS_FPIN:
        return "not an FPIN (0x%02x)" % cmd
    if dlen != len(p) - 8:
        return "bad descriptor list length %d (payload %d)" % (dlen, len(p))
    tag, = struct.unpack_from(">I", p, 8)
    if tag in (DTAG_LI, DTAG_PN):
        if tag == DTAG_LI:
            _, _, det, att, typ, _, thr, cnt, n = struct.unpack_from(">IIQQHHIII", p, 8)
            head = "li type=%d detecting=%s attached=%s threshold=%d count=%d" % (
                typ, wwpn(det), wwpn(att), thr, cnt)
            off = 8 + struct.calcsize(">IIQQHHIII")
        else:
            _, _, det, att, typ, _, per, n = struct.unpack_from(">IIQQHHII", p, 8)
            head = "pn type=%d detecting=%s attached=%s period=%d" % (
                typ, wwpn(det), wwpn(att), per)
            # struct fc_fn_peer_congn_desc pads 4 bytes before pname_list
            # (FC-LS puts the list right after pname_count); the kernel and
            # multipathd read it with the struct, and fcsim builds it so.
            off = 8 + struct.calcsize(">IIQQHHII") + 4
        names = struct.unpack_from(">%dQ" % n, p, off)
        return "%s pnames=%s" % (head, ",".join(wwpn(x) for x in names))
    if tag == DTAG_DN:
        _, _, det, att, reason = struct.unpack_from(">IIQQI", p, 8)
        return "dn reason=%d detecting=%s attached=%s" % (reason, wwpn(det), wwpn(att))
    if tag == DTAG_CN:
        _, _, typ, _, per, sev = struct.unpack_from(">IIHHIB", p, 8)
        return "cn type=%d period=%d severity=0x%02x" % (typ, per, sev)
    return "unknown descriptor 0x%08x" % tag


def main():
    duration = float(sys.argv[1])
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW,
                         NETLINK_SCSITRANSPORT)
    sock.bind((0, GROUP_MASK))
    print("listening", flush=True)
    deadline = time.monotonic() + duration
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        sock.settimeout(left)
        try:
            data = sock.recv(65536)
        except socket.timeout:
            break
        (_, _, host_no, dlen, _, code, edata) = FC_NL_EVENT.unpack_from(data, OFFSET)
        line = "host%d %s 0x%06x" % (host_no, EVENTS.get(code, hex(code)), edata)
        if code == FCH_EVT_LINK_FPIN:
            line += " " + decode_fpin(data[DATA:DATA + dlen])
        print(line, flush=True)


if __name__ == "__main__":
    main()

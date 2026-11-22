#!/usr/bin/python3
"""Print FC transport netlink events (fc_host_post_event) for a while.

    fc-events.py <seconds>

The first line is "listening" once the socket is bound: events posted after
it are caught (start_events in tests/lib.sh waits for it).  Then each line:
"host<N> <event name> 0x<event data>".
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
        (_, _, host_no, _, _, code, edata) = FC_NL_EVENT.unpack_from(data, OFFSET)
        print("host%d %s 0x%06x" % (host_no, EVENTS.get(code, hex(code)), edata),
              flush=True)


if __name__ == "__main__":
    main()

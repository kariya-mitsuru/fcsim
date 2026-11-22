// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: Fabric Performance Impact Notifications sent by the fabric.
 *
 *   /sys/kernel/config/fcsim/fpin   (wo) one notification per write:
 *
 *     li <wwpn> [<event>] [count=<n>] [threshold=<ms>]
 *         Link Integrity: the link of port <wwpn> has errors.
 *         <event>: link_failure (default) | loss_of_sync | loss_of_signal |
 *                  prim_seq_err | invalid_tx_word | invalid_crc |
 *                  device_specific | unknown
 *     pn <wwpn> [<event>] [period=<ms>]
 *         Peer Congestion: port <wwpn> is congested.
 *     dn <wwpn> [<reason>]
 *         Delivery: frames to / from <wwpn> were discarded.
 *         <reason>: timeout (default) | unable_to_route | device_specific | unknown
 *     cn <initiator wwpn> [<event>] [severity=warning|error] [period=<ms>]
 *         Congestion on that initiator port's own link.
 *     (pn / cn <event>: credit_stall (default) | lost_credit |
 *      oversubscription | device_specific | clear)
 *
 * About a target port, the FPIN goes to every initiator port that is up
 * and zoned with it, as a switch would do; about an initiator port, only
 * to that port.  The target port need not be online (enabled TPG): the
 * notification is what a test asks for, e.g. about a port that just went
 * away.  It is delivered as a real ELS FPIN payload through
 * fc_host_fpin_rcv(): the FC transport counts it (fc_host and rport
 * statistics/fpin_*) and posts it as an FC netlink event, which is what
 * multipathd's "marginal_pathgroups fpin" reacts to.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/slab.h>
#include <linux/string.h>
#include <linux/kstrtox.h>
#include <linux/configfs.h>
#include <scsi/scsi_host.h>
#include <scsi/scsi_transport_fc.h>
#include <uapi/scsi/fc/fc_els.h>

#include "fcsim.h"

enum fcsim_fpin_kind { FPIN_K_LI, FPIN_K_PN, FPIN_K_DN, FPIN_K_CN };

struct fcsim_fpin_name {
	const char	*name;
	u16		value;
};

static const struct fcsim_fpin_name fcsim_li_events[] = {
	{ "link_failure",	FPIN_LI_LINK_FAILURE },
	{ "loss_of_sync",	FPIN_LI_LOSS_OF_SYNC },
	{ "loss_of_signal",	FPIN_LI_LOSS_OF_SIG },
	{ "prim_seq_err",	FPIN_LI_PRIM_SEQ_ERR },
	{ "invalid_tx_word",	FPIN_LI_INVALID_TX_WD },
	{ "invalid_crc",	FPIN_LI_INVALID_CRC },
	{ "device_specific",	FPIN_LI_DEVICE_SPEC },
	{ "unknown",		FPIN_LI_UNKNOWN },
	{ }
};

static const struct fcsim_fpin_name fcsim_congn_events[] = {
	{ "credit_stall",	FPIN_CONGN_CREDIT_STALL },
	{ "lost_credit",	FPIN_CONGN_LOST_CREDIT },
	{ "oversubscription",	FPIN_CONGN_OVERSUBSCRIPTION },
	{ "device_specific",	FPIN_CONGN_DEVICE_SPEC },
	{ "clear",		FPIN_CONGN_CLEAR },
	{ }
};

static const struct fcsim_fpin_name fcsim_deli_reasons[] = {
	{ "timeout",		FPIN_DELI_TIMEOUT },
	{ "unable_to_route",	FPIN_DELI_UNABLE_TO_ROUTE },
	{ "device_specific",	FPIN_DELI_DEVICE_SPEC },
	{ "unknown",		FPIN_DELI_UNKNOWN },
	{ }
};

static const struct {
	const char			*name;
	const struct fcsim_fpin_name	*events;	/* the first is the default */
} fcsim_fpin_kinds[] = {
	[FPIN_K_LI] = { "li", fcsim_li_events },
	[FPIN_K_PN] = { "pn", fcsim_congn_events },
	[FPIN_K_DN] = { "dn", fcsim_deli_reasons },
	[FPIN_K_CN] = { "cn", fcsim_congn_events },
};

/* A parsed request. */
struct fcsim_fpin_req {
	enum fcsim_fpin_kind	kind;
	u64			wwpn;
	u16			event;
	u32			count;		/* li */
	u32			threshold;	/* li, ms */
	u32			period;		/* pn / cn, ms */
	u8			severity;	/* cn */
};

/* Largest payload we build: ELS header + LI descriptor with one port name. */
#define FCSIM_FPIN_MAX_LEN	(sizeof(struct fc_els_fpin) + \
				 sizeof(struct fc_fn_li_desc) + sizeof(__be64))

static int fcsim_fpin_lookup(const struct fcsim_fpin_name *t, const char *s,
			     u16 *value)
{
	for (; t->name; t++)
		if (!strcmp(t->name, s)) {
			*value = t->value;
			return 0;
		}
	return -EINVAL;
}

static int fcsim_fpin_parse(char *line, struct fcsim_fpin_req *r)
{
	const struct fcsim_fpin_name *events;
	char *tok, *kind, *wwpn;
	unsigned int k;
	int ret;

	kind = strsep(&line, " \t\n");
	wwpn = strsep(&line, " \t\n");
	if (!kind || !wwpn)
		return -EINVAL;

	memset(r, 0, sizeof(*r));
	r->count = 1;
	r->threshold = 1000;
	r->period = 1000;
	r->severity = FPIN_CONGN_SEVERITY_WARNING;
	for (k = 0; k < ARRAY_SIZE(fcsim_fpin_kinds); k++)
		if (!strcmp(kind, fcsim_fpin_kinds[k].name))
			break;
	if (k == ARRAY_SIZE(fcsim_fpin_kinds))
		return -EINVAL;
	r->kind = k;
	events = fcsim_fpin_kinds[k].events;
	r->event = events[0].value;

	ret = fcsim_parse_wwn(wwpn, &r->wwpn);
	if (ret)
		return ret;

	while ((tok = strsep(&line, " \t\n"))) {
		char *val;

		if (!*tok)
			continue;
		val = strchr(tok, '=');
		if (!val) {
			if (fcsim_fpin_lookup(events, tok, &r->event))
				return -EINVAL;
			continue;
		}
		*val++ = '\0';
		if (!strcmp(tok, "count") && r->kind == FPIN_K_LI)
			ret = kstrtou32(val, 0, &r->count);
		else if (!strcmp(tok, "threshold") && r->kind == FPIN_K_LI)
			ret = kstrtou32(val, 0, &r->threshold);
		else if (!strcmp(tok, "period") &&
			 (r->kind == FPIN_K_PN || r->kind == FPIN_K_CN))
			ret = kstrtou32(val, 0, &r->period);
		else if (!strcmp(tok, "severity") && r->kind == FPIN_K_CN) {
			if (!strcmp(val, "warning"))
				r->severity = FPIN_CONGN_SEVERITY_WARNING;
			else if (!strcmp(val, "error"))
				r->severity = FPIN_CONGN_SEVERITY_ERROR;
			else
				ret = -EINVAL;
		} else {
			ret = -EINVAL;
		}
		if (ret)
			return ret;
	}
	return 0;
}

/* WWPN of the (virtual) switch port that @port_id is attached to. */
static u64 fcsim_switch_port_wwpn(u32 port_id)
{
	return (0x20ULL << 56) | ((u64)((port_id >> 8) & 0xff) << 48) |
	       (fcsim_fabric_wwn & 0xffffffffffffULL);
}

/* Build the ELS FPIN payload into @buf; returns its length. */
static u32 fcsim_fpin_build(const struct fcsim_fpin_req *r, u32 port_id,
			    void *buf)
{
	struct fc_els_fpin *fpin = buf;
	void *desc = fpin->fpin_desc;
	__be64 detecting = cpu_to_be64(fcsim_switch_port_wwpn(port_id));
	__be64 attached = cpu_to_be64(r->wwpn);
	u32 dlen;

	memset(buf, 0, FCSIM_FPIN_MAX_LEN);
	fpin->fpin_cmd = ELS_FPIN;

	switch (r->kind) {
	case FPIN_K_LI: {
		struct fc_fn_li_desc *d = desc;

		/*
		 * The port name list holds the N_Ports reached through the
		 * attached port: here the port itself.  multipathd only looks
		 * at this list (the kernel skips the attached port in it when
		 * counting, so nothing is counted twice).
		 */
		dlen = sizeof(*d) + sizeof(__be64);
		d->desc_tag = cpu_to_be32(ELS_DTAG_LNK_INTEGRITY);
		d->desc_len = cpu_to_be32(dlen - FC_TLV_DESC_HDR_SZ);
		d->detecting_wwpn = detecting;
		d->attached_wwpn = attached;
		d->event_type = cpu_to_be16(r->event);
		d->event_threshold = cpu_to_be32(r->threshold);
		d->event_count = cpu_to_be32(r->count);
		d->pname_count = cpu_to_be32(1);
		d->pname_list[0] = attached;
		break;
	}
	case FPIN_K_PN: {
		struct fc_fn_peer_congn_desc *d = desc;

		dlen = sizeof(*d) + sizeof(__be64);	/* see LI above */
		d->desc_tag = cpu_to_be32(ELS_DTAG_PEER_CONGEST);
		d->desc_len = cpu_to_be32(dlen - FC_TLV_DESC_HDR_SZ);
		d->detecting_wwpn = detecting;
		d->attached_wwpn = attached;
		d->event_type = cpu_to_be16(r->event);
		d->event_period = cpu_to_be32(r->period);
		d->pname_count = cpu_to_be32(1);
		d->pname_list[0] = attached;
		break;
	}
	case FPIN_K_DN: {
		struct fc_fn_deli_desc *d = desc;

		d->desc_tag = cpu_to_be32(ELS_DTAG_DELIVERY);
		d->desc_len = cpu_to_be32(FC_TLV_DESC_LENGTH_FROM_SZ(*d));
		d->detecting_wwpn = detecting;
		d->attached_wwpn = attached;
		d->deli_reason_code = cpu_to_be32(r->event);
		dlen = sizeof(*d);
		break;
	}
	case FPIN_K_CN:
	default: {
		struct fc_fn_congn_desc *d = desc;

		d->desc_tag = cpu_to_be32(ELS_DTAG_CONGESTION);
		d->desc_len = cpu_to_be32(FC_TLV_DESC_LENGTH_FROM_SZ(*d));
		d->event_type = cpu_to_be16(r->event);
		d->event_period = cpu_to_be32(r->period);
		d->severity = r->severity;
		dlen = sizeof(*d);
		break;
	}
	}
	fpin->desc_len = cpu_to_be32(dlen);
	return sizeof(*fpin) + dlen;
}

static int fcsim_fpin_send(const struct fcsim_fpin_req *r)
{
	struct fcsim_iport *iport;
	struct fcsim_tport *tport, *about_t = NULL;
	struct fcsim_iport *about_i = NULL;
	unsigned int sent = 0;
	char name[FCSIM_WWN_BUFLEN];
	u32 port_id, len;
	void *buf;

	buf = kmalloc(FCSIM_FPIN_MAX_LEN, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	mutex_lock(&fcsim_mutex);
	list_for_each_entry(iport, &fcsim_iports, node)
		if (iport->wwpn == r->wwpn)
			about_i = iport;
	list_for_each_entry(tport, &fcsim_tports, node)
		if (tport->wwpn == r->wwpn)
			about_t = tport;

	if (r->kind == FPIN_K_CN ? !about_i : !about_i && !about_t) {
		mutex_unlock(&fcsim_mutex);
		kfree(buf);
		return -ENODEV;
	}
	port_id = about_i ? about_i->port_id : about_t->port_id;
	len = fcsim_fpin_build(r, port_id, buf);

	list_for_each_entry(iport, &fcsim_iports, node) {
		if (!fcsim_iport_online(iport))
			continue;
		if (about_i ? iport != about_i :
		    !fcsim_zone_allows(iport->wwpn, about_t->wwpn))
			continue;
		fc_host_fpin_rcv(iport->shost, len, buf, 0);
		sent++;
	}
	mutex_unlock(&fcsim_mutex);
	kfree(buf);

	fcsim_format_wwn(name, sizeof(name), r->wwpn);
	pr_info("FPIN %s about %s (event 0x%x) sent to %u port(s)\n",
		fcsim_fpin_kinds[r->kind].name, name, r->event, sent);
	return 0;
}

static ssize_t fcsim_root_fpin_store(struct config_item *item,
				     const char *page, size_t count)
{
	struct fcsim_fpin_req r;
	char *line;
	int ret;

	line = kstrndup(page, count, GFP_KERNEL);
	if (!line)
		return -ENOMEM;
	ret = fcsim_fpin_parse(line, &r);
	kfree(line);
	if (!ret)
		ret = fcsim_fpin_send(&r);
	return ret ? ret : count;
}

/* Listed in the root's attributes (fcsim_cfs.c). */
struct configfs_attribute fcsim_root_attr_fpin = {
	.ca_name	= "fpin",
	.ca_owner	= THIS_MODULE,
	.ca_mode	= 0200,
	.store		= fcsim_root_fpin_store,
};

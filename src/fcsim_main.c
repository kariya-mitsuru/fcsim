// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: module init/exit and the virtual fabric.
 *
 * The fabric owns the lists of initiator ports (iports) and target ports
 * (tports) and decides which (iport, tport) pairs are logged in.  All state
 * changes are made under fcsim_mutex and then "reconciled" on a single
 * ordered workqueue, which performs the actual logins/logouts.
 *
 * A logout terminates the initiator's exchanges and unpublishes the nexus
 * under fcsim_mutex; draining its LIO session (which waits for commands
 * inside the backend) runs on a separate workqueue, so one stuck backend
 * does not stall the whole fabric.  The same pair logs in again only once
 * the old session is gone, so its old commands cannot overtake new ones.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/module.h>
#include <linux/idr.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/device.h>
#include <linux/string.h>
#include <linux/ratelimit.h>
#include <target/target_core_fabric.h>

#include "fcsim.h"

DEFINE_MUTEX(fcsim_mutex);
LIST_HEAD(fcsim_iports);
/* Initiator ports still being set up: their WWPNs are taken already. */
LIST_HEAD(fcsim_iports_creating);
LIST_HEAD(fcsim_tports);

/* WWN of the (single) virtual switch, shown as fc_host fabric_name. */
u64 fcsim_fabric_wwn = 0x100000fc5f000001ULL;

struct device *fcsim_root_dev;

static DEFINE_IDA(fcsim_port_ida);
static struct workqueue_struct *fcsim_wq;	/* ordered: reconcile */
static struct workqueue_struct *fcsim_drain_wq;	/* session drains */
static DECLARE_WAIT_QUEUE_HEAD(fcsim_drain_waitq);
static u32 fcsim_nexus_index;

static void fcsim_fabric_work_fn(struct work_struct *work);
static DECLARE_WORK(fcsim_fabric_work, fcsim_fabric_work_fn);

/* ---------------------------------------------------------------- WWN utils */

/* Accept only canonical "xx:xx:xx:xx:xx:xx:xx:xx" (lower case), optional '\n'. */
int fcsim_parse_wwn(const char *str, u64 *wwn)
{
	size_t len = strlen(str);
	u64 v = 0;
	int i;

	if (len && str[len - 1] == '\n')
		len--;
	if (len != FCSIM_WWN_STRLEN)
		return -EINVAL;

	for (i = 0; i < FCSIM_WWN_STRLEN; i++) {
		char c = str[i];

		if (i % 3 == 2) {
			if (c != ':')
				return -EINVAL;
			continue;
		}
		if (c >= '0' && c <= '9')
			v = (v << 4) | (c - '0');
		else if (c >= 'a' && c <= 'f')
			v = (v << 4) | (c - 'a' + 10);
		else
			return -EINVAL;
	}
	if (!v)
		return -EINVAL;

	*wwn = v;
	return 0;
}

void fcsim_format_wwn(char *buf, size_t len, u64 wwn)
{
	snprintf(buf, len, "%02x:%02x:%02x:%02x:%02x:%02x:%02x:%02x",
		 (u8)(wwn >> 56), (u8)(wwn >> 48), (u8)(wwn >> 40),
		 (u8)(wwn >> 32), (u8)(wwn >> 24), (u8)(wwn >> 16),
		 (u8)(wwn >> 8), (u8)wwn);
}

/* Default WWNN: the WWPN with its first byte replaced by 0x20. */
u64 fcsim_default_wwnn(u64 wwpn)
{
	u64 wwnn = (wwpn & ~(0xffULL << 56)) | (0x20ULL << 56);

	if (wwnn == wwpn)
		wwnn ^= 1ULL << 60;
	return wwnn;
}

/* ------------------------------------------------------------- port ids */

int fcsim_port_id_alloc(u32 *port_id)
{
	int area = ida_alloc_range(&fcsim_port_ida, 1, FCSIM_MAX_PORTS, GFP_KERNEL);

	if (area < 0)
		return area;
	*port_id = (FCSIM_DOMAIN_ID << 16) | (area << 8);
	return 0;
}

void fcsim_port_id_free(u32 port_id)
{
	ida_free(&fcsim_port_ida, (port_id >> 8) & 0xff);
}

/* Caller holds fcsim_mutex. */
bool fcsim_wwpn_in_use(u64 wwpn)
{
	struct fcsim_iport *iport;
	struct fcsim_tport *tport;

	lockdep_assert_held(&fcsim_mutex);

	list_for_each_entry(iport, &fcsim_iports, node)
		if (iport->wwpn == wwpn)
			return true;
	list_for_each_entry(iport, &fcsim_iports_creating, node)
		if (iport->wwpn == wwpn)
			return true;
	list_for_each_entry(tport, &fcsim_tports, node)
		if (tport->wwpn == wwpn)
			return true;
	return false;
}

/* ------------------------------------------------------------- attributes */

/*
 * One WWN per line in a configfs attribute (one page).  Names that do not
 * fit are counted in *more and reported by fcsim_emit_more().
 */
#define FCSIM_MORE_RESERVE	32

ssize_t fcsim_emit_name(char *page, ssize_t len, const char *name,
			unsigned int *more)
{
	if (len + strlen(name) + 1 + FCSIM_MORE_RESERVE > PAGE_SIZE) {
		(*more)++;
		return len;
	}
	return len + sysfs_emit_at(page, len, "%s\n", name);
}

ssize_t fcsim_emit_more(char *page, ssize_t len, unsigned int more)
{
	if (more)
		len += sysfs_emit_at(page, len, "... %u more\n", more);
	return len;
}

/* ------------------------------------------------------------- refusals */

/*
 * Logins the target refused (no ACL and demo mode off).  Every reconcile
 * retries them, so only a change in the outcome is logged at info level.
 */
struct fcsim_refusal {
	struct list_head	node;		/* iport->refused_list */
	struct fcsim_tport	*tport;
	int			err;
};

static struct fcsim_refusal *fcsim_refusal_find(struct fcsim_iport *iport,
						struct fcsim_tport *tport)
{
	struct fcsim_refusal *r;

	list_for_each_entry(r, &iport->refused_list, node)
		if (r->tport == tport)
			return r;
	return NULL;
}

/* Returns true if this refusal is news (and should be logged). */
static bool fcsim_note_refusal(struct fcsim_iport *iport,
			       struct fcsim_tport *tport, int err)
{
	struct fcsim_refusal *r = fcsim_refusal_find(iport, tport);

	if (r) {
		if (r->err == err)
			return false;
		r->err = err;
		return true;
	}
	r = kzalloc(sizeof(*r), GFP_KERNEL);
	if (!r) {
		/* Cannot remember it: log, but not on every retry. */
		static DEFINE_RATELIMIT_STATE(rs, 60 * HZ, 1);

		return __ratelimit(&rs);
	}
	r->tport = tport;
	r->err = err;
	list_add_tail(&r->node, &iport->refused_list);
	return true;
}

/*
 * Forget refusals of @iport (all if @tport is NULL), or of @tport on every
 * iport (if @iport is NULL).  Caller holds fcsim_mutex.
 */
void fcsim_forget_refusals(struct fcsim_iport *iport, struct fcsim_tport *tport)
{
	struct fcsim_refusal *r, *tmp;
	struct fcsim_iport *ip;

	lockdep_assert_held(&fcsim_mutex);

	if (!iport) {
		list_for_each_entry(ip, &fcsim_iports, node)
			fcsim_forget_refusals(ip, tport);
		return;
	}
	list_for_each_entry_safe(r, tmp, &iport->refused_list, node) {
		if (tport && r->tport != tport)
			continue;
		list_del(&r->node);
		kfree(r);
	}
}

/* ------------------------------------------------------------- nexus */

/* Caller holds rcu_read_lock(); used by the I/O path. */
struct fcsim_nexus *fcsim_nexus_lookup_rcu(struct fcsim_iport *iport,
					   u64 tport_wwpn)
{
	struct fcsim_nexus *nexus;

	list_for_each_entry_rcu(nexus, &iport->nexus_list, iport_node)
		if (nexus->tport_wwpn == tport_wwpn)
			return nexus;
	return NULL;
}

static struct fcsim_nexus *fcsim_nexus_find(struct fcsim_iport *iport,
					    struct fcsim_tport *tport)
{
	struct fcsim_nexus *nexus;

	list_for_each_entry(nexus, &iport->nexus_list, iport_node)
		if (nexus->tport == tport)
			return nexus;
	return NULL;
}

static bool fcsim_nexus_wanted(struct fcsim_nexus *nexus)
{
	return nexus->iport->link_up && !nexus->iport->removing &&
	       fcsim_tport_online(nexus->tport) && !READ_ONCE(nexus->closing) &&
	       fcsim_zone_allows(nexus->iport->wwpn, nexus->tport->wwpn);
}

/* PLOGI/PRLI equivalent. */
static void fcsim_login(struct fcsim_iport *iport, struct fcsim_tport *tport)
{
	struct fcsim_nexus *nexus;
	int ret;

	nexus = kzalloc(sizeof(*nexus), GFP_KERNEL);
	if (!nexus)
		return;

	nexus->iport = iport;
	nexus->tport = tport;
	nexus->tport_wwpn = tport->wwpn;
	nexus->index = ++fcsim_nexus_index;
	init_completion(&nexus->close_done);

	ret = fcsim_tgt_login(nexus);
	if (ret) {
		if (fcsim_note_refusal(iport, tport, ret))
			pr_info("login %s -> %s rejected by target (%d)\n",
				iport->name, tport->name, ret);
		else
			pr_debug("login %s -> %s still rejected (%d)\n",
				 iport->name, tport->name, ret);
		kfree(nexus);
		return;
	}
	fcsim_forget_refusals(iport, tport);

	/* Publish to the I/O path before the rport goes online. */
	list_add_tail(&nexus->tport_node, &tport->nexus_list);
	list_add_tail_rcu(&nexus->iport_node, &iport->nexus_list);

	ret = fcsim_rport_add(nexus);
	if (ret) {
		pr_err("login %s -> %s: rport add failed (%d)\n",
		       iport->name, tport->name, ret);
		list_del_rcu(&nexus->iport_node);
		list_del(&nexus->tport_node);
		synchronize_rcu();
		fcsim_tgt_logout(nexus);
		kfree(nexus);
		return;
	}

	pr_info("login %s -> %s (port_id 0x%06x)\n",
		iport->name, tport->name, tport->port_id);
}

/* Wait until every logged-out session counted in @ndraining is gone. */
void fcsim_wait_drained(atomic_t *ndraining)
{
	wait_event(fcsim_drain_waitq, !atomic_read(ndraining));
}

static void fcsim_drain_work_fn(struct work_struct *work)
{
	struct fcsim_nexus *nexus = container_of(work, struct fcsim_nexus,
						 drain_work);
	/* The ports stay alive until their ndraining drops to zero. */
	atomic_t *tport_cnt = &nexus->tport->ndraining;
	atomic_t *iport_cnt = &nexus->iport->ndraining;

	/* After this no I/O path lookup can still be using the nexus. */
	synchronize_rcu();

	/* Waits for commands still inside LIO / the backend. */
	fcsim_tgt_logout(nexus);
	pr_debug("session %u drained\n", nexus->index);

	mutex_lock(&fcsim_mutex);
	list_del(&nexus->drain_node);
	mutex_unlock(&fcsim_mutex);
	kfree(nexus);

	atomic_dec(tport_cnt);
	atomic_dec(iport_cnt);
	wake_up_all(&fcsim_drain_waitq);

	/* The pair may log in again. */
	fcsim_fabric_kick();
}

static bool fcsim_pair_draining(struct fcsim_iport *iport,
				struct fcsim_tport *tport)
{
	struct fcsim_nexus *nexus;

	list_for_each_entry(nexus, &iport->draining_list, drain_node)
		if (nexus->tport == tport)
			return true;
	return false;
}

/* LOGO equivalent.  The session is drained asynchronously. */
static void fcsim_logout(struct fcsim_nexus *nexus)
{
	struct fcsim_iport *iport = nexus->iport;

	pr_info("logout %s -> %s\n", iport->name, nexus->tport->name);

	/* Block new I/O at the SCSI layer first; dev_loss_tmo starts here. */
	fcsim_rport_delete(nexus);

	list_del_rcu(&nexus->iport_node);
	list_del(&nexus->tport_node);
	list_add_tail(&nexus->drain_node, &iport->draining_list);

	/* LOGO implicitly aborts every open exchange of this login. */
	fcsim_terminate_tport(iport, nexus->tport_wwpn);

	atomic_inc(&nexus->tport->ndraining);
	atomic_inc(&iport->ndraining);
	INIT_WORK(&nexus->drain_work, fcsim_drain_work_fn);
	queue_work(fcsim_drain_wq, &nexus->drain_work);
}

static void fcsim_reconcile(void)
{
	struct fcsim_iport *iport;
	struct fcsim_tport *tport;
	struct fcsim_nexus *nexus, *tmp;

	lockdep_assert_held(&fcsim_mutex);

	list_for_each_entry(iport, &fcsim_iports, node)
		list_for_each_entry_safe(nexus, tmp, &iport->nexus_list, iport_node)
			if (!fcsim_nexus_wanted(nexus))
				fcsim_logout(nexus);

	/* RSCN: tell the initiators about target ports joining or leaving. */
	list_for_each_entry(tport, &fcsim_tports, node) {
		bool online = fcsim_tport_online(tport);

		if (online == tport->rscn_online)
			continue;
		tport->rscn_online = online;
		/* A new appearance of the port: report refusals afresh. */
		fcsim_forget_refusals(NULL, tport);
		/* Like a switch, only to the initiators zoned with it. */
		list_for_each_entry(iport, &fcsim_iports, node)
			if (iport->link_up && !iport->removing &&
			    fcsim_zone_allows(iport->wwpn, tport->wwpn))
				fcsim_post_rscn(iport, tport->port_id);
	}

	list_for_each_entry(iport, &fcsim_iports, node) {
		if (!iport->link_up || iport->removing) {
			fcsim_forget_refusals(iport, NULL);
			continue;
		}
		list_for_each_entry(tport, &fcsim_tports, node) {
			if (!fcsim_tport_online(tport))
				continue;
			if (!fcsim_zone_allows(iport->wwpn, tport->wwpn) ||
			    fcsim_nexus_find(iport, tport) ||
			    fcsim_pair_draining(iport, tport))
				continue;
			fcsim_login(iport, tport);
		}
	}
}

static void fcsim_fabric_work_fn(struct work_struct *work)
{
	mutex_lock(&fcsim_mutex);
	fcsim_reconcile();
	mutex_unlock(&fcsim_mutex);
}

/*
 * Schedule a reconcile.  Safe from any context that may hold LIO locks
 * (ACL creation, close_session, attribute stores).
 */
void fcsim_fabric_kick(void)
{
	queue_work(fcsim_wq, &fcsim_fabric_work);
}

/*
 * Reconcile and wait for it.  Must not be called with fcsim_mutex held or
 * from a context the worker could wait on.
 */
void fcsim_fabric_sync(void)
{
	queue_work(fcsim_wq, &fcsim_fabric_work);
	flush_work(&fcsim_fabric_work);
}

/* ------------------------------------------------------------- module */

static int __init fcsim_init(void)
{
	int ret;

	fcsim_wq = alloc_ordered_workqueue("fcsim_fabric", WQ_MEM_RECLAIM);
	if (!fcsim_wq)
		return -ENOMEM;
	fcsim_drain_wq = alloc_workqueue("fcsim_drain",
					 WQ_UNBOUND | WQ_MEM_RECLAIM, 0);
	if (!fcsim_drain_wq) {
		ret = -ENOMEM;
		goto out_wq;
	}

	fcsim_root_dev = root_device_register(FCSIM_NAME);
	if (IS_ERR(fcsim_root_dev)) {
		ret = PTR_ERR(fcsim_root_dev);
		goto out_wq;
	}

	ret = fcsim_ini_init();
	if (ret)
		goto out_root;

	ret = fcsim_tgt_init();
	if (ret)
		goto out_ini;

	ret = fcsim_cfs_init();
	if (ret)
		goto out_tgt;

	pr_info("version %s loaded\n", FCSIM_VERSION);
	return 0;

out_tgt:
	fcsim_tgt_exit();
out_ini:
	fcsim_ini_exit();
out_root:
	root_device_unregister(fcsim_root_dev);
out_wq:
	if (fcsim_drain_wq)
		destroy_workqueue(fcsim_drain_wq);
	destroy_workqueue(fcsim_wq);
	return ret;
}

static void __exit fcsim_exit(void)
{
	/* configfs pins the module while any host or target port exists. */
	fcsim_cfs_exit();
	fcsim_tgt_exit();
	fcsim_ini_exit();
	root_device_unregister(fcsim_root_dev);
	destroy_workqueue(fcsim_drain_wq);
	destroy_workqueue(fcsim_wq);
	ida_destroy(&fcsim_port_ida);
	pr_info("unloaded\n");
}

module_init(fcsim_init);
module_exit(fcsim_exit);

MODULE_DESCRIPTION("Software-only Fibre Channel SCSI loopback for LIO");
MODULE_LICENSE("GPL");
MODULE_VERSION(FCSIM_VERSION);

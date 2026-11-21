// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: module init/exit and the virtual fabric.
 *
 * The fabric owns the lists of initiator ports (iports) and target ports
 * (tports) and decides which (iport, tport) pairs are logged in.  All state
 * changes are made under fcsim_mutex and then "reconciled" on a single
 * ordered workqueue, which performs the actual logins/logouts.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/module.h>
#include <linux/idr.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/device.h>
#include <linux/string.h>
#include <target/target_core_fabric.h>

#include "fcsim.h"

DEFINE_MUTEX(fcsim_mutex);
LIST_HEAD(fcsim_iports);
LIST_HEAD(fcsim_tports);

/* WWN of the (single) virtual switch, shown as fc_host fabric_name. */
u64 fcsim_fabric_wwn = 0x100000fc5f000001ULL;

struct device *fcsim_root_dev;

static DEFINE_IDA(fcsim_port_ida);
static struct workqueue_struct *fcsim_wq;
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
	list_for_each_entry(tport, &fcsim_tports, node)
		if (tport->wwpn == wwpn)
			return true;
	return false;
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
	       fcsim_tport_online(nexus->tport) && !READ_ONCE(nexus->closing);
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

	ret = fcsim_tgt_login(nexus);
	if (ret) {
		pr_info("login %s -> %s rejected by target (%d)\n",
			iport->name, tport->name, ret);
		kfree(nexus);
		return;
	}

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

/* LOGO equivalent. */
static void fcsim_logout(struct fcsim_nexus *nexus)
{
	pr_info("logout %s -> %s\n", nexus->iport->name, nexus->tport->name);

	/* Block new I/O at the SCSI layer first; dev_loss_tmo starts here. */
	fcsim_rport_delete(nexus);

	list_del_rcu(&nexus->iport_node);
	list_del(&nexus->tport_node);
	synchronize_rcu();

	/* No new commands can find the session now; drain and remove it. */
	fcsim_tgt_logout(nexus);
	kfree(nexus);
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

	list_for_each_entry(iport, &fcsim_iports, node) {
		if (!iport->link_up || iport->removing)
			continue;
		list_for_each_entry(tport, &fcsim_tports, node) {
			if (!fcsim_tport_online(tport))
				continue;
			if (fcsim_nexus_find(iport, tport))
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
	destroy_workqueue(fcsim_wq);
	ida_destroy(&fcsim_port_ida);
	pr_info("unloaded\n");
}

module_init(fcsim_init);
module_exit(fcsim_exit);

MODULE_DESCRIPTION("Software-only Fibre Channel SCSI loopback for LIO");
MODULE_LICENSE("GPL");
MODULE_VERSION(FCSIM_VERSION);

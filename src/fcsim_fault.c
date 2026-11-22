// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: fault injection on the virtual fabric.
 *
 *   /sys/kernel/config/fcsim/hosts/<initiator WWPN>/faults/<target WWPN | any>/
 *     delay_ms      deliver commands to the target this much later
 *     drop          none | cmd (never delivered) | rsp (executed, response lost)
 *                   Task management requests are dropped too (no response).
 *     error         none | transport | busy | qfull | medium | aborted:
 *                   answer immediately with this error, without delivering
 *     probability   percentage of matching commands affected (default 100)
 *     count         affect only this many more commands (-1 = unlimited)
 *     injected      (ro) commands affected so far
 *
 * A rule for a specific target port takes precedence over "any".  The
 * fabric only applies the rules; scenarios are up to user space.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/slab.h>
#include <linux/string.h>
#include <linux/random.h>
#include <linux/sysfs.h>
#include <linux/kstrtox.h>
#include <linux/configfs.h>

#include "fcsim.h"

struct fcsim_fault {
	struct config_group	group;
	struct list_head	node;		/* iport->faults */
	struct rcu_head		rcu;
	struct fcsim_iport	*iport;
	u64			tport_wwpn;	/* 0: any target port */
	u32			delay_ms;
	u8			drop;		/* enum fcsim_drop */
	u8			error;		/* enum fcsim_error */
	u8			probability;
	atomic_t		count;
	atomic64_t		injected;
};

#define FCSIM_FAULT_MAX_DELAY_MS	(3600 * 1000)

static const char *const fcsim_drop_names[] = {
	[FCSIM_DROP_NONE]	= "none",
	[FCSIM_DROP_CMD]	= "cmd",
	[FCSIM_DROP_RSP]	= "rsp",
};

static const char *const fcsim_error_names[] = {
	[FCSIM_ERR_NONE]	= "none",
	[FCSIM_ERR_TRANSPORT]	= "transport",
	[FCSIM_ERR_BUSY]	= "busy",
	[FCSIM_ERR_QFULL]	= "qfull",
	[FCSIM_ERR_MEDIUM]	= "medium",
	[FCSIM_ERR_ABORTED]	= "aborted",
};

/*
 * Decide what happens to the next command (or TMR) from @iport to
 * @tport_wwpn.  Any context.
 */
bool fcsim_fault_eval(struct fcsim_iport *iport, u64 tport_wwpn, bool tmr,
		      struct fcsim_fault_action *act)
{
	struct fcsim_fault *f, *rule = NULL;
	bool hit = false;
	u8 p;

	memset(act, 0, sizeof(*act));
	if (list_empty(&iport->faults))	/* fast path, racy but harmless */
		return false;

	rcu_read_lock();
	list_for_each_entry_rcu(f, &iport->faults, node) {
		if (f->tport_wwpn == tport_wwpn) {
			rule = f;
			break;
		}
		if (!f->tport_wwpn && !rule)
			rule = f;
	}
	if (!rule)
		goto out;

	act->delay_ms = READ_ONCE(rule->delay_ms);
	act->drop = READ_ONCE(rule->drop);
	act->error = READ_ONCE(rule->error);
	if (tmr) {
		/* Only "no response" applies to task management. */
		if (act->drop == FCSIM_DROP_NONE)
			goto out;
		act->delay_ms = 0;
		act->error = FCSIM_ERR_NONE;
	} else if (!act->delay_ms && act->drop == FCSIM_DROP_NONE &&
		   act->error == FCSIM_ERR_NONE) {
		goto out;
	}

	p = READ_ONCE(rule->probability);
	if (p < 100 && get_random_u32_below(100) >= p)
		goto out;
	if (atomic_read(&rule->count) != -1 &&
	    atomic_dec_if_positive(&rule->count) < 0)
		goto out;

	atomic64_inc(&rule->injected);
	hit = true;
out:
	rcu_read_unlock();
	if (!hit)
		memset(act, 0, sizeof(*act));
	return hit;
}

/* ------------------------------------------------------------- rule item */

static inline struct fcsim_fault *to_fault(struct config_item *item)
{
	return container_of(to_config_group(item), struct fcsim_fault, group);
}

static ssize_t fcsim_fault_delay_ms_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%u\n", READ_ONCE(to_fault(item)->delay_ms));
}

static ssize_t fcsim_fault_delay_ms_store(struct config_item *item,
					  const char *page, size_t count)
{
	u32 val;
	int ret;

	ret = kstrtou32(page, 0, &val);
	if (ret)
		return ret;
	if (val > FCSIM_FAULT_MAX_DELAY_MS)
		return -ERANGE;
	WRITE_ONCE(to_fault(item)->delay_ms, val);
	return count;
}

static ssize_t fcsim_fault_drop_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n",
			  fcsim_drop_names[READ_ONCE(to_fault(item)->drop)]);
}

static ssize_t fcsim_fault_drop_store(struct config_item *item,
				      const char *page, size_t count)
{
	int i = sysfs_match_string(fcsim_drop_names, page);

	if (i < 0)
		return i;
	WRITE_ONCE(to_fault(item)->drop, i);
	return count;
}

static ssize_t fcsim_fault_error_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n",
			  fcsim_error_names[READ_ONCE(to_fault(item)->error)]);
}

static ssize_t fcsim_fault_error_store(struct config_item *item,
				       const char *page, size_t count)
{
	int i = sysfs_match_string(fcsim_error_names, page);

	if (i < 0)
		return i;
	WRITE_ONCE(to_fault(item)->error, i);
	return count;
}

static ssize_t fcsim_fault_probability_show(struct config_item *item,
					    char *page)
{
	return sysfs_emit(page, "%u\n", READ_ONCE(to_fault(item)->probability));
}

static ssize_t fcsim_fault_probability_store(struct config_item *item,
					     const char *page, size_t count)
{
	u8 val;
	int ret;

	ret = kstrtou8(page, 0, &val);
	if (ret)
		return ret;
	if (val > 100)
		return -ERANGE;
	WRITE_ONCE(to_fault(item)->probability, val);
	return count;
}

static ssize_t fcsim_fault_count_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%d\n", atomic_read(&to_fault(item)->count));
}

static ssize_t fcsim_fault_count_store(struct config_item *item,
				       const char *page, size_t count)
{
	int val, ret;

	ret = kstrtoint(page, 0, &val);
	if (ret)
		return ret;
	if (val < -1)
		return -ERANGE;
	atomic_set(&to_fault(item)->count, val);
	return count;
}

static ssize_t fcsim_fault_injected_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%lld\n",
			  (long long)atomic64_read(&to_fault(item)->injected));
}

CONFIGFS_ATTR(fcsim_fault_, delay_ms);
CONFIGFS_ATTR(fcsim_fault_, drop);
CONFIGFS_ATTR(fcsim_fault_, error);
CONFIGFS_ATTR(fcsim_fault_, probability);
CONFIGFS_ATTR(fcsim_fault_, count);
CONFIGFS_ATTR_RO(fcsim_fault_, injected);

static struct configfs_attribute *fcsim_fault_attrs[] = {
	&fcsim_fault_attr_delay_ms,
	&fcsim_fault_attr_drop,
	&fcsim_fault_attr_error,
	&fcsim_fault_attr_probability,
	&fcsim_fault_attr_count,
	&fcsim_fault_attr_injected,
	NULL,
};

static void fcsim_fault_release(struct config_item *item)
{
	struct fcsim_fault *f = to_fault(item);

	kfree_rcu(f, rcu);	/* the I/O path may still be looking at it */
}

static struct configfs_item_operations fcsim_fault_item_ops = {
	.release	= fcsim_fault_release,
};

static const struct config_item_type fcsim_fault_type = {
	.ct_item_ops	= &fcsim_fault_item_ops,
	.ct_attrs	= fcsim_fault_attrs,
	.ct_owner	= THIS_MODULE,
};

/* ------------------------------------------------------------- faults group */

static struct config_group *fcsim_faults_make_group(struct config_group *group,
						    const char *name)
{
	struct fcsim_iport *iport = container_of(group, struct fcsim_iport,
						 faults_group);
	struct fcsim_fault *f;
	unsigned long flags;
	u64 wwpn = 0;

	if (strcmp(name, "any") && fcsim_parse_wwn(name, &wwpn)) {
		pr_err("fault rule name must be a target WWPN or \"any\": %s\n",
		       name);
		return ERR_PTR(-EINVAL);
	}

	f = kzalloc(sizeof(*f), GFP_KERNEL);
	if (!f)
		return ERR_PTR(-ENOMEM);
	f->iport = iport;
	f->tport_wwpn = wwpn;
	f->probability = 100;
	atomic_set(&f->count, -1);
	atomic64_set(&f->injected, 0);
	config_group_init_type_name(&f->group, name, &fcsim_fault_type);

	spin_lock_irqsave(&iport->fault_lock, flags);
	list_add_tail_rcu(&f->node, &iport->faults);
	spin_unlock_irqrestore(&iport->fault_lock, flags);

	return &f->group;
}

static void fcsim_faults_drop_item(struct config_group *group,
				   struct config_item *item)
{
	struct fcsim_fault *f = to_fault(item);
	unsigned long flags;

	spin_lock_irqsave(&f->iport->fault_lock, flags);
	list_del_rcu(&f->node);
	spin_unlock_irqrestore(&f->iport->fault_lock, flags);

	config_item_put(item);
}

static struct configfs_group_operations fcsim_faults_group_ops = {
	.make_group	= fcsim_faults_make_group,
	.drop_item	= fcsim_faults_drop_item,
};

const struct config_item_type fcsim_faults_type = {
	.ct_group_ops	= &fcsim_faults_group_ops,
	.ct_owner	= THIS_MODULE,
};

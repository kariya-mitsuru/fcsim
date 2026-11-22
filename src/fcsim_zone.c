// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: zoning (WWN zoning on the single virtual switch).
 *
 *   /sys/kernel/config/fcsim/
 *     zoning/
 *       mode        off | on           staged, takes effect on commit
 *       commit      (wo) make the staged configuration the active one
 *       pending     (ro) 1 if the staged configuration differs from the active
 *       active      (ro, binary) the active configuration:
 *                     mode <off|on>
 *                     zone <name> <wwpn> <wwpn> ...
 *     zones/<name>/
 *       members     staged WWPNs, one per line (a write replaces the list)
 *
 * With mode off every initiator sees every target port.  With mode on an
 * initiator port and a target port may log in to each other only if some
 * zone contains both.  Editing never affects the fabric; commit swaps in an
 * immutable copy and reconciles once, so the fabric never goes through an
 * intermediate state.  Initiators whose view changes get an RSCN.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/moduleparam.h>
#include <linux/string.h>
#include <linux/sort.h>
#include <linux/bsearch.h>
#include <linux/sysfs.h>
#include <linux/kstrtox.h>
#include <linux/configfs.h>

#include "fcsim.h"

#define FCSIM_ZONE_MAX_MEMBERS	128	/* also keeps "members" within a page */
#define FCSIM_ZONE_MAX_ZONES	1024
#define FCSIM_ZONE_ACTIVE_MAX	(1024 * 1024)

/* A staged zone: /sys/kernel/config/fcsim/zones/<name>. */
struct fcsim_zone {
	struct config_group	group;
	struct list_head	node;		/* fcsim_staged_zones */
	unsigned int		nmembers;
	u64			*members;	/* sorted, unique */
};

/* An active (committed) configuration; immutable. */
struct fcsim_zs_zone {
	const char		*name;
	unsigned int		nmembers;
	u64			*members;	/* sorted, unique */
};

struct fcsim_zoneset {
	bool			on;
	unsigned int		nzones;
	struct fcsim_zs_zone	zones[];	/* sorted by name */
};

/*
 * Staged configuration.  Lock order: fcsim_zone_mutex, then fcsim_mutex
 * (commit and pending compare the staged configuration with the active one).
 */
static DEFINE_MUTEX(fcsim_zone_mutex);
static LIST_HEAD(fcsim_staged_zones);
static bool fcsim_staged_on;

/* Active configuration; fcsim_mutex.  Never NULL while loaded. */
static struct fcsim_zoneset *fcsim_active_zs;

/* ------------------------------------------------------------- zonesets */

static int fcsim_cmp_u64(const void *a, const void *b)
{
	u64 x = *(const u64 *)a, y = *(const u64 *)b;

	return x < y ? -1 : x > y;
}

static int fcsim_cmp_zs_zone(const void *a, const void *b)
{
	return strcmp(((const struct fcsim_zs_zone *)a)->name,
		      ((const struct fcsim_zs_zone *)b)->name);
}

static void fcsim_zoneset_free(struct fcsim_zoneset *zs)
{
	unsigned int i;

	if (!zs)
		return;
	for (i = 0; i < zs->nzones; i++) {
		kfree(zs->zones[i].name);
		kfree(zs->zones[i].members);
	}
	kfree(zs);
}

/* Snapshot of the staged configuration.  Caller holds fcsim_zone_mutex. */
static struct fcsim_zoneset *fcsim_zoneset_from_staged(void)
{
	struct fcsim_zoneset *zs;
	struct fcsim_zone *z;
	unsigned int n = 0;

	lockdep_assert_held(&fcsim_zone_mutex);

	list_for_each_entry(z, &fcsim_staged_zones, node)
		n++;
	zs = kzalloc(struct_size(zs, zones, n), GFP_KERNEL);
	if (!zs)
		return ERR_PTR(-ENOMEM);
	zs->on = fcsim_staged_on;

	list_for_each_entry(z, &fcsim_staged_zones, node) {
		struct fcsim_zs_zone *d = &zs->zones[zs->nzones];

		d->name = kstrdup(config_item_name(&z->group.cg_item), GFP_KERNEL);
		d->members = kmemdup(z->members, z->nmembers * sizeof(u64),
				     GFP_KERNEL);
		d->nmembers = z->nmembers;
		zs->nzones++;
		if (!d->name || (z->nmembers && !d->members)) {
			fcsim_zoneset_free(zs);
			return ERR_PTR(-ENOMEM);
		}
	}
	sort(zs->zones, zs->nzones, sizeof(zs->zones[0]), fcsim_cmp_zs_zone, NULL);
	return zs;
}

static bool fcsim_zoneset_equal(const struct fcsim_zoneset *a,
				const struct fcsim_zoneset *b)
{
	unsigned int i;

	if (a->on != b->on || a->nzones != b->nzones)
		return false;
	for (i = 0; i < a->nzones; i++) {
		const struct fcsim_zs_zone *x = &a->zones[i], *y = &b->zones[i];

		if (strcmp(x->name, y->name) || x->nmembers != y->nmembers ||
		    memcmp(x->members, y->members, x->nmembers * sizeof(u64)))
			return false;
	}
	return true;
}

static bool fcsim_zs_zone_has(const struct fcsim_zs_zone *z, u64 wwpn)
{
	return bsearch(&wwpn, z->members, z->nmembers, sizeof(u64),
		       fcsim_cmp_u64);
}

static bool fcsim_zoneset_allows(const struct fcsim_zoneset *zs, u64 a, u64 b)
{
	unsigned int i;

	if (!zs->on)
		return true;
	for (i = 0; i < zs->nzones; i++)
		if (fcsim_zs_zone_has(&zs->zones[i], a) &&
		    fcsim_zs_zone_has(&zs->zones[i], b))
			return true;
	return false;
}

/* May @iwwpn and @twwpn log in to each other?  Caller holds fcsim_mutex. */
bool fcsim_zone_allows(u64 iwwpn, u64 twwpn)
{
	lockdep_assert_held(&fcsim_mutex);
	return fcsim_zoneset_allows(fcsim_active_zs, iwwpn, twwpn);
}

/*
 * RSCN to every initiator whose view of an online target port changes when
 * @new replaces @old.  Caller holds fcsim_mutex.
 */
static void fcsim_zone_rscn(const struct fcsim_zoneset *old,
			    const struct fcsim_zoneset *new)
{
	struct fcsim_iport *iport;
	struct fcsim_tport *tport;

	list_for_each_entry(iport, &fcsim_iports, node) {
		if (!iport->link_up || iport->removing)
			continue;
		list_for_each_entry(tport, &fcsim_tports, node) {
			if (!fcsim_tport_online(tport))
				continue;
			if (fcsim_zoneset_allows(old, iport->wwpn, tport->wwpn) !=
			    fcsim_zoneset_allows(new, iport->wwpn, tport->wwpn))
				fcsim_post_rscn(iport, tport->port_id);
		}
	}
}

/*
 * Test-only knob that widens a race window (tests/zone-fcsim.sh): the next
 * commit sleeps this long between taking its snapshot and making it active.
 * 0 (off) by default.
 */
static unsigned int dbg_commit_delay_ms;
module_param(dbg_commit_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_commit_delay_ms,
		 "test only: delay the next zoning commit after its snapshot (one-shot)");

static int fcsim_zone_commit(void)
{
	struct fcsim_zoneset *new, *old;
	unsigned int delay;

	/*
	 * Keep the staged configuration locked until the snapshot is active:
	 * otherwise a concurrent commit with a newer snapshot could become
	 * active first and then be replaced by this older one.
	 */
	mutex_lock(&fcsim_zone_mutex);
	new = fcsim_zoneset_from_staged();
	if (IS_ERR(new)) {
		mutex_unlock(&fcsim_zone_mutex);
		return PTR_ERR(new);
	}

	delay = xchg(&dbg_commit_delay_ms, 0);
	if (delay)
		msleep(delay);

	mutex_lock(&fcsim_mutex);
	old = fcsim_active_zs;
	fcsim_zone_rscn(old, new);
	fcsim_active_zs = new;
	/* Once unlocked, a later commit may free @new. */
	pr_info("zoning committed: mode %s, %u zone(s)\n",
		new->on ? "on" : "off", new->nzones);
	mutex_unlock(&fcsim_mutex);
	mutex_unlock(&fcsim_zone_mutex);

	fcsim_zoneset_free(old);

	/* Log the affected pairs out and in. */
	fcsim_fabric_sync();
	return 0;
}

/* ------------------------------------------------------------- zones/<name> */

static inline struct fcsim_zone *to_zone(struct config_item *item)
{
	return container_of(to_config_group(item), struct fcsim_zone, group);
}

static ssize_t fcsim_zone_members_show(struct config_item *item, char *page)
{
	struct fcsim_zone *z = to_zone(item);
	char buf[FCSIM_WWN_BUFLEN];
	unsigned int i, more = 0;
	ssize_t len = 0;

	mutex_lock(&fcsim_zone_mutex);
	for (i = 0; i < z->nmembers; i++) {
		fcsim_format_wwn(buf, sizeof(buf), z->members[i]);
		len = fcsim_emit_name(page, len, buf, &more);
	}
	mutex_unlock(&fcsim_zone_mutex);
	return fcsim_emit_more(page, len, more);
}

/* WWPNs separated by white space (or commas); replaces the list. */
static ssize_t fcsim_zone_members_store(struct config_item *item,
					const char *page, size_t count)
{
	struct fcsim_zone *z = to_zone(item);
	unsigned int n = 0, i, j;
	char *copy, *p, *tok;
	u64 *members;
	int ret = 0;

	members = kcalloc(FCSIM_ZONE_MAX_MEMBERS, sizeof(u64), GFP_KERNEL);
	copy = kstrndup(page, count, GFP_KERNEL);
	if (!members || !copy) {
		ret = -ENOMEM;
		goto out;
	}

	p = copy;
	while ((tok = strsep(&p, " \t\n,"))) {
		u64 wwpn;

		if (!*tok)
			continue;
		if (fcsim_parse_wwn(tok, &wwpn)) {
			pr_err("zone %s: invalid WWPN %s\n",
			       config_item_name(item), tok);
			ret = -EINVAL;
			goto out;
		}
		if (n == FCSIM_ZONE_MAX_MEMBERS) {
			ret = -E2BIG;
			goto out;
		}
		members[n++] = wwpn;
	}

	sort(members, n, sizeof(u64), fcsim_cmp_u64, NULL);
	for (i = j = 0; i < n; i++)		/* drop duplicates */
		if (!j || members[j - 1] != members[i])
			members[j++] = members[i];

	mutex_lock(&fcsim_zone_mutex);
	swap(z->members, members);
	z->nmembers = j;
	mutex_unlock(&fcsim_zone_mutex);
out:
	kfree(copy);
	kfree(members);
	return ret ? ret : count;
}

CONFIGFS_ATTR(fcsim_zone_, members);

static struct configfs_attribute *fcsim_zone_attrs[] = {
	&fcsim_zone_attr_members,
	NULL,
};

static void fcsim_zone_release(struct config_item *item)
{
	struct fcsim_zone *z = to_zone(item);

	kfree(z->members);
	kfree(z);
}

static struct configfs_item_operations fcsim_zone_item_ops = {
	.release	= fcsim_zone_release,
};

static const struct config_item_type fcsim_zone_type = {
	.ct_item_ops	= &fcsim_zone_item_ops,
	.ct_attrs	= fcsim_zone_attrs,
	.ct_owner	= THIS_MODULE,
};

static struct config_group *fcsim_zones_make_group(struct config_group *group,
						   const char *name)
{
	struct fcsim_zone *z, *iter;
	unsigned int n = 0;
	const char *c;

	for (c = name; *c; c++)
		if (*c <= ' ' || *c == ',' || *c > '~')
			return ERR_PTR(-EINVAL);	/* one word in "active" */

	z = kzalloc(sizeof(*z), GFP_KERNEL);
	if (!z)
		return ERR_PTR(-ENOMEM);
	config_group_init_type_name(&z->group, name, &fcsim_zone_type);

	mutex_lock(&fcsim_zone_mutex);
	list_for_each_entry(iter, &fcsim_staged_zones, node)
		n++;
	if (n >= FCSIM_ZONE_MAX_ZONES) {
		mutex_unlock(&fcsim_zone_mutex);
		kfree(z);
		return ERR_PTR(-ENOSPC);
	}
	list_add_tail(&z->node, &fcsim_staged_zones);
	mutex_unlock(&fcsim_zone_mutex);

	return &z->group;
}

static void fcsim_zones_drop_item(struct config_group *group,
				  struct config_item *item)
{
	mutex_lock(&fcsim_zone_mutex);
	list_del(&to_zone(item)->node);
	mutex_unlock(&fcsim_zone_mutex);
	config_item_put(item);
}

static struct configfs_group_operations fcsim_zones_group_ops = {
	.make_group	= fcsim_zones_make_group,
	.drop_item	= fcsim_zones_drop_item,
};

static const struct config_item_type fcsim_zones_type = {
	.ct_group_ops	= &fcsim_zones_group_ops,
	.ct_owner	= THIS_MODULE,
};

static struct config_group fcsim_zones_group;

/* ------------------------------------------------------------- zoning/ */

static ssize_t fcsim_zoning_mode_show(struct config_item *item, char *page)
{
	bool on;

	mutex_lock(&fcsim_zone_mutex);
	on = fcsim_staged_on;
	mutex_unlock(&fcsim_zone_mutex);
	return sysfs_emit(page, "%s\n", on ? "on" : "off");
}

static ssize_t fcsim_zoning_mode_store(struct config_item *item,
				       const char *page, size_t count)
{
	bool on;

	if (sysfs_streq(page, "on"))
		on = true;
	else if (sysfs_streq(page, "off"))
		on = false;
	else if (kstrtobool(page, &on))
		return -EINVAL;

	mutex_lock(&fcsim_zone_mutex);
	fcsim_staged_on = on;
	mutex_unlock(&fcsim_zone_mutex);
	return count;
}

static ssize_t fcsim_zoning_commit_store(struct config_item *item,
					 const char *page, size_t count)
{
	bool doit;
	int ret;

	if (kstrtobool(page, &doit) || !doit)
		return -EINVAL;
	ret = fcsim_zone_commit();
	return ret ? ret : count;
}

static ssize_t fcsim_zoning_pending_show(struct config_item *item, char *page)
{
	struct fcsim_zoneset *staged;
	bool pending;

	mutex_lock(&fcsim_zone_mutex);
	staged = fcsim_zoneset_from_staged();
	if (IS_ERR(staged)) {
		mutex_unlock(&fcsim_zone_mutex);
		return PTR_ERR(staged);
	}
	mutex_lock(&fcsim_mutex);
	pending = !fcsim_zoneset_equal(staged, fcsim_active_zs);
	mutex_unlock(&fcsim_mutex);
	mutex_unlock(&fcsim_zone_mutex);

	fcsim_zoneset_free(staged);
	return sysfs_emit(page, "%d\n", pending);
}

/* Length of the text of @zs (see the top of the file). */
static size_t fcsim_zoning_active_len(const struct fcsim_zoneset *zs)
{
	size_t len = strlen(zs->on ? "mode on\n" : "mode off\n");
	unsigned int i;

	for (i = 0; i < zs->nzones; i++)
		len += strlen("zone ") + strlen(zs->zones[i].name) +
		       zs->zones[i].nmembers * (1 + FCSIM_WWN_STRLEN) + 1;
	return len;
}

static void fcsim_zoning_active_text(const struct fcsim_zoneset *zs, char *buf)
{
	char wwn[FCSIM_WWN_BUFLEN];
	unsigned int i, j;

	buf += sprintf(buf, "mode %s\n", zs->on ? "on" : "off");
	for (i = 0; i < zs->nzones; i++) {
		const struct fcsim_zs_zone *z = &zs->zones[i];

		buf += sprintf(buf, "zone %s", z->name);
		for (j = 0; j < z->nmembers; j++) {
			fcsim_format_wwn(wwn, sizeof(wwn), z->members[j]);
			buf += sprintf(buf, " %s", wwn);
		}
		buf += sprintf(buf, "\n");
	}
}

/*
 * configfs asks for the size first (buf == NULL), then reads exactly that
 * many bytes.  A commit in between may change the text: if it no longer
 * fits it is cut at a line boundary, and the rest is padded with newlines
 * (readers skip empty lines).
 */
static ssize_t fcsim_zoning_active_read(struct config_item *item, void *buf,
					size_t size)
{
	size_t len;
	char *text;

	mutex_lock(&fcsim_mutex);
	len = fcsim_zoning_active_len(fcsim_active_zs);
	if (!buf) {
		mutex_unlock(&fcsim_mutex);
		return len;
	}
	text = kmalloc(len + 1, GFP_KERNEL);
	if (!text) {
		mutex_unlock(&fcsim_mutex);
		return -ENOMEM;
	}
	fcsim_zoning_active_text(fcsim_active_zs, text);
	mutex_unlock(&fcsim_mutex);

	if (len > size) {
		len = size;
		while (len && text[len - 1] != '\n')
			len--;
	}
	memcpy(buf, text, len);
	memset(buf + len, '\n', size - len);
	kfree(text);
	return size;
}

CONFIGFS_ATTR(fcsim_zoning_, mode);
CONFIGFS_ATTR_WO(fcsim_zoning_, commit);
CONFIGFS_ATTR_RO(fcsim_zoning_, pending);
CONFIGFS_BIN_ATTR_RO(fcsim_zoning_, active, NULL, FCSIM_ZONE_ACTIVE_MAX);

static struct configfs_attribute *fcsim_zoning_attrs[] = {
	&fcsim_zoning_attr_mode,
	&fcsim_zoning_attr_commit,
	&fcsim_zoning_attr_pending,
	NULL,
};

static struct configfs_bin_attribute *fcsim_zoning_bin_attrs[] = {
	&fcsim_zoning_attr_active,
	NULL,
};

static const struct config_item_type fcsim_zoning_type = {
	.ct_attrs	= fcsim_zoning_attrs,
	.ct_bin_attrs	= fcsim_zoning_bin_attrs,
	.ct_owner	= THIS_MODULE,
};

static struct config_group fcsim_zoning_group;

/* ------------------------------------------------------------- init/exit */

int fcsim_zone_init(struct config_group *root)
{
	fcsim_active_zs = kzalloc(sizeof(*fcsim_active_zs), GFP_KERNEL);
	if (!fcsim_active_zs)
		return -ENOMEM;

	config_group_init_type_name(&fcsim_zoning_group, "zoning",
				    &fcsim_zoning_type);
	configfs_add_default_group(&fcsim_zoning_group, root);
	config_group_init_type_name(&fcsim_zones_group, "zones",
				    &fcsim_zones_type);
	configfs_add_default_group(&fcsim_zones_group, root);
	return 0;
}

/* After the configfs subsystem is gone. */
void fcsim_zone_exit(void)
{
	fcsim_zoneset_free(fcsim_active_zs);
	fcsim_active_zs = NULL;
}

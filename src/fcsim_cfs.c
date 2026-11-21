// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: initiator-side / fabric configuration.
 *
 *   /sys/kernel/config/fcsim/
 *     fabric_name, version                 (ro)
 *     hosts/<initiator WWPN>/              mkdir = create a virtual HBA port
 *       port_name, port_id, scsi_host, targets   (ro)
 *       node_name                          (rw while link is down)
 *       link                               (rw: up / down)
 *       draining                           (ro) logged-out sessions not yet drained
 *       faults/<target WWPN | any>/        fault injection rules (fcsim_fault.c)
 *   zoning/, zones/                        zoning (fcsim_zone.c)
 *   fpin                                   (wo) send an FPIN (fcsim_fpin.c)
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/configfs.h>
#include <scsi/scsi_host.h>

#include "fcsim.h"

static inline struct fcsim_iport *to_iport(struct config_item *item)
{
	return container_of(to_config_group(item), struct fcsim_iport, group);
}

/* ------------------------------------------------------------- host item */

static ssize_t fcsim_host_port_name_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n", to_iport(item)->name);
}

static ssize_t fcsim_host_node_name_show(struct config_item *item, char *page)
{
	char buf[FCSIM_WWN_BUFLEN];

	fcsim_format_wwn(buf, sizeof(buf), to_iport(item)->wwnn);
	return sysfs_emit(page, "%s\n", buf);
}

static ssize_t fcsim_host_node_name_store(struct config_item *item,
					  const char *page, size_t count)
{
	u64 wwnn;
	int ret;

	ret = fcsim_parse_wwn(page, &wwnn);
	if (ret)
		return ret;
	ret = fcsim_iport_set_wwnn(to_iport(item), wwnn);
	return ret ? ret : count;
}

static ssize_t fcsim_host_port_id_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "0x%06x\n", to_iport(item)->port_id);
}

static ssize_t fcsim_host_scsi_host_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "host%u\n", to_iport(item)->shost->host_no);
}

static ssize_t fcsim_host_link_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n", to_iport(item)->link_up ? "up" : "down");
}

static ssize_t fcsim_host_link_store(struct config_item *item,
				     const char *page, size_t count)
{
	bool up;

	if (sysfs_streq(page, "up"))
		up = true;
	else if (sysfs_streq(page, "down"))
		up = false;
	else if (kstrtobool(page, &up))
		return -EINVAL;

	fcsim_iport_set_link(to_iport(item), up);
	return count;
}

/* Target ports this initiator is currently logged in to. */
static ssize_t fcsim_host_targets_show(struct config_item *item, char *page)
{
	struct fcsim_iport *iport = to_iport(item);
	struct fcsim_nexus *nexus;
	unsigned int more = 0;
	ssize_t len = 0;

	mutex_lock(&fcsim_mutex);
	list_for_each_entry(nexus, &iport->nexus_list, iport_node)
		len = fcsim_emit_name(page, len, nexus->tport->name, &more);
	mutex_unlock(&fcsim_mutex);
	return fcsim_emit_more(page, len, more);
}

static ssize_t fcsim_host_draining_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%d\n", atomic_read(&to_iport(item)->ndraining));
}

CONFIGFS_ATTR_RO(fcsim_host_, port_name);
CONFIGFS_ATTR(fcsim_host_, node_name);
CONFIGFS_ATTR_RO(fcsim_host_, port_id);
CONFIGFS_ATTR_RO(fcsim_host_, scsi_host);
CONFIGFS_ATTR(fcsim_host_, link);
CONFIGFS_ATTR_RO(fcsim_host_, targets);
CONFIGFS_ATTR_RO(fcsim_host_, draining);

static struct configfs_attribute *fcsim_host_attrs[] = {
	&fcsim_host_attr_port_name,
	&fcsim_host_attr_node_name,
	&fcsim_host_attr_port_id,
	&fcsim_host_attr_scsi_host,
	&fcsim_host_attr_link,
	&fcsim_host_attr_targets,
	&fcsim_host_attr_draining,
	NULL,
};

static void fcsim_host_release(struct config_item *item)
{
	kfree(to_iport(item));
}

static struct configfs_item_operations fcsim_host_item_ops = {
	.release	= fcsim_host_release,
};

static const struct config_item_type fcsim_host_type = {
	.ct_item_ops	= &fcsim_host_item_ops,
	.ct_attrs	= fcsim_host_attrs,
	.ct_owner	= THIS_MODULE,
};

/* ------------------------------------------------------------- hosts group */

static struct config_group *fcsim_hosts_make_group(struct config_group *group,
						   const char *name)
{
	struct fcsim_iport *iport;
	u64 wwpn;

	if (fcsim_parse_wwn(name, &wwpn)) {
		pr_err("invalid initiator WWPN: %s (use xx:xx:...:xx)\n", name);
		return ERR_PTR(-EINVAL);
	}

	iport = fcsim_iport_create(wwpn);
	if (IS_ERR(iport))
		return ERR_CAST(iport);

	config_group_init_type_name(&iport->group, name, &fcsim_host_type);
	config_group_init_type_name(&iport->faults_group, "faults",
				    &fcsim_faults_type);
	configfs_add_default_group(&iport->faults_group, &iport->group);
	return &iport->group;
}

static void fcsim_hosts_drop_item(struct config_group *group,
				  struct config_item *item)
{
	struct fcsim_iport *iport = to_iport(item);

	/* configfs refuses the rmdir while fault rules exist. */
	configfs_remove_default_groups(&iport->group);
	fcsim_iport_destroy(iport);
	config_item_put(item);
}

static struct configfs_group_operations fcsim_hosts_group_ops = {
	.make_group	= fcsim_hosts_make_group,
	.drop_item	= fcsim_hosts_drop_item,
};

static const struct config_item_type fcsim_hosts_type = {
	.ct_group_ops	= &fcsim_hosts_group_ops,
	.ct_owner	= THIS_MODULE,
};

static struct config_group fcsim_hosts_group;

/* ------------------------------------------------------------- root */

static ssize_t fcsim_root_fabric_name_show(struct config_item *item, char *page)
{
	char buf[FCSIM_WWN_BUFLEN];

	fcsim_format_wwn(buf, sizeof(buf), fcsim_fabric_wwn);
	return sysfs_emit(page, "%s\n", buf);
}

static ssize_t fcsim_root_version_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n", FCSIM_VERSION);
}

CONFIGFS_ATTR_RO(fcsim_root_, fabric_name);
CONFIGFS_ATTR_RO(fcsim_root_, version);

static struct configfs_attribute *fcsim_root_attrs[] = {
	&fcsim_root_attr_fabric_name,
	&fcsim_root_attr_version,
	&fcsim_root_attr_fpin,
	NULL,
};

static const struct config_item_type fcsim_root_type = {
	.ct_attrs	= fcsim_root_attrs,
	.ct_owner	= THIS_MODULE,
};

static struct configfs_subsystem fcsim_subsys = {
	.su_group = {
		.cg_item = {
			.ci_namebuf	= FCSIM_FABRIC_NAME,
			.ci_type	= &fcsim_root_type,
		},
	},
};

int fcsim_cfs_init(void)
{
	int ret;

	config_group_init(&fcsim_subsys.su_group);
	mutex_init(&fcsim_subsys.su_mutex);

	config_group_init_type_name(&fcsim_hosts_group, "hosts",
				    &fcsim_hosts_type);
	configfs_add_default_group(&fcsim_hosts_group, &fcsim_subsys.su_group);

	ret = fcsim_zone_init(&fcsim_subsys.su_group);	/* zoning/, zones/ */
	if (ret)
		return ret;

	ret = configfs_register_subsystem(&fcsim_subsys);
	if (ret) {
		pr_err("configfs_register_subsystem failed: %d\n", ret);
		fcsim_zone_exit();
	}
	return ret;
}

void fcsim_cfs_exit(void)
{
	configfs_unregister_subsystem(&fcsim_subsys);
	fcsim_zone_exit();
}

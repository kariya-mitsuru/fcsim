// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: target side, a LIO fabric module named "fcsim".
 *
 *   /sys/kernel/config/target/fcsim/<target WWPN>/tpgt_1/{lun,acls,attrib,enable}
 *
 * TPG attributes and their defaults follow tcm_qla2xxx, so any initiator
 * can log in but only sees LUNs through an explicit ACL.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/stringify.h>
#include <scsi/scsi_cmnd.h>
#include <scsi/scsi_host.h>
#include <scsi/scsi_proto.h>
#include <target/target_core_base.h>
#include <target/target_core_fabric.h>

#include "fcsim.h"

static const struct target_core_fabric_ops fcsim_ops;

/*
 * Test-only knobs that widen race windows (tests/race-fcsim.sh).  Both are 0
 * (off) by default.
 */
static unsigned int dbg_release_delay_ms;
module_param(dbg_release_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_release_delay_ms,
		 "test only: delay freeing the next completed READ (one-shot)");

static unsigned int dbg_close_delay_ms;
module_param(dbg_close_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_close_delay_ms,
		 "test only: sleep at the start of close_session");

static inline struct fcsim_tport *tpg_to_tport(struct se_portal_group *se_tpg)
{
	return container_of(se_tpg, struct fcsim_tport, se_tpg);
}

static inline struct fcsim_tport *wwn_to_tport(struct se_wwn *wwn)
{
	return container_of(wwn, struct fcsim_tport, se_wwn);
}

/* Caller holds fcsim_mutex. */
bool fcsim_tport_online(struct fcsim_tport *tport)
{
	return tport->tpg_registered && tport->enabled;
}

/* ------------------------------------------------------------- sessions */

/* Caller holds fcsim_mutex; process context. */
int fcsim_tgt_login(struct fcsim_nexus *nexus)
{
	struct se_session *se_sess;

	/* -EACCES if there is no ACL and demo mode is disabled. */
	se_sess = target_setup_session(&nexus->tport->se_tpg, 0, 0,
				       TARGET_PROT_NORMAL, nexus->iport->name,
				       nexus, NULL);
	if (IS_ERR(se_sess))
		return PTR_ERR(se_sess);

	nexus->se_sess = se_sess;
	return 0;
}

/*
 * Drain worker, without fcsim_mutex: the nexus is no longer reachable from
 * the I/O path.  May wait for commands stuck in the backend.
 */
void fcsim_tgt_logout(struct fcsim_nexus *nexus)
{
	struct se_session *se_sess = nexus->se_sess;
	struct se_node_acl *nacl = se_sess->se_node_acl;
	unsigned long flags;
	bool close_in_flight;

	/*
	 * target_shutdown_sessions() picks a session that is not stopped off
	 * the ACL's list under nacl_sess_lock, drops the lock and then calls
	 * close_session().  Stopping the session under the same lock makes
	 * the two exclusive: either LIO has already taken the session off the
	 * list (close_session() is running or about to run, so wait for it
	 * before the session and nexus are freed), or it will skip it.
	 * target_stop_session() does not sleep.
	 */
	spin_lock_irqsave(&nacl->nacl_sess_lock, flags);
	target_stop_session(se_sess);
	close_in_flight = list_empty(&se_sess->sess_acl_list);
	spin_unlock_irqrestore(&nacl->nacl_sess_lock, flags);
	if (close_in_flight)
		wait_for_completion(&nexus->close_done);

	target_wait_for_sess_cmds(se_sess);
	target_remove_session(se_sess);
	nexus->se_sess = NULL;
}

/* LIO wants the session gone (e.g. its ACL is being deleted). */
static void fcsim_close_session(struct se_session *se_sess)
{
	struct fcsim_nexus *nexus;
	unsigned int delay = READ_ONCE(dbg_close_delay_ms);

	if (delay)
		msleep(delay);

	nexus = se_sess->fabric_sess_ptr;
	WRITE_ONCE(nexus->closing, true);
	fcsim_fabric_kick();
	/* Last access: the nexus and session may be freed right after this. */
	complete(&nexus->close_done);
}

static u32 fcsim_sess_get_index(struct se_session *se_sess)
{
	struct fcsim_nexus *nexus = se_sess->fabric_sess_ptr;

	return nexus->index;
}

/* ------------------------------------------------------------- commands */

static int fcsim_check_stop_free(struct se_cmd *se_cmd)
{
	/*
	 * LIO calls this after taking the command off the device state list
	 * but before release_cmd, i.e. inside the window where ABORT_TASK
	 * answers TASK_DOES_NOT_EXIST for a command that is still alive.
	 * One-shot: only the next READ is delayed.
	 */
	if (READ_ONCE(dbg_release_delay_ms) && se_cmd->t_task_cdb &&
	    (se_cmd->t_task_cdb[0] == READ_10 || se_cmd->t_task_cdb[0] == READ_16)) {
		unsigned int delay = xchg(&dbg_release_delay_ms, 0);

		/* Sleep when we can, so the CPU's blk-mq timeout work still runs. */
		if (delay && preemptible())
			msleep(delay);
		else if (delay)
			mdelay(delay);
	}

	return transport_generic_free_cmd(se_cmd, 0);
}

static inline struct fcsim_cmd *to_cmd(struct se_cmd *se_cmd)
{
	return container_of(se_cmd, struct fcsim_cmd, se_cmd);
}

static void fcsim_release_cmd(struct se_cmd *se_cmd)
{
	struct fcsim_cmd *cmd = to_cmd(se_cmd);

	if (se_cmd->se_cmd_flags & SCF_SCSI_TMR_CDB)
		fcsim_xchg_put(cmd);	/* LIO's reference; EH holds its own */
	else
		fcsim_xchg_released(cmd);
}

static int fcsim_write_pending(struct se_cmd *se_cmd)
{
	/* "XFER_RDY": pull the data from the initiator, if still there. */
	if (!fcsim_xchg_fetch_write_data(to_cmd(se_cmd))) {
		/* The initiator terminated the exchange: no data will come. */
		transport_generic_request_failure(se_cmd,
						  TCM_CHECK_CONDITION_ABORT_CMD);
		return 0;
	}
	target_execute_cmd(se_cmd);
	return 0;
}

static int fcsim_queue_data_in(struct se_cmd *se_cmd)
{
	fcsim_xchg_status(to_cmd(se_cmd), true);
	return 0;
}

static int fcsim_queue_status(struct se_cmd *se_cmd)
{
	fcsim_xchg_status(to_cmd(se_cmd), false);
	return 0;
}

static void fcsim_queue_tm_rsp(struct se_cmd *se_cmd)
{
	struct fcsim_cmd *cmd = to_cmd(se_cmd);
	unsigned long flags;
	bool abandoned;

	spin_lock_irqsave(&cmd->lock, flags);
	abandoned = cmd->tmr_state == FCSIM_TMR_ABANDONED;
	if (abandoned) {
		/* Too late: EH no longer waits. */
	} else if (cmd->drop_rsp) {
		/*
		 * Fault: the FCP_RSP is lost in the fabric.  EH keeps waiting
		 * until tmr_timeout and then drops the ACK reference itself.
		 */
		cmd->tmr_state = FCSIM_TMR_LOST;
	} else {
		cmd->tmr_state = FCSIM_TMR_RESPONDED;
		complete(&cmd->tmr_done);
	}
	spin_unlock_irqrestore(&cmd->lock, flags);

	/*
	 * SCSI EH stopped waiting: drop the ACK reference it would have
	 * dropped.  LIO still holds its own until check_stop_free.
	 */
	if (abandoned)
		target_put_sess_cmd(se_cmd);
}

/*
 * Aborted without TAS (e.g. by a LUN reset from the same initiator): LIO
 * calls this instead of queue_tm_rsp / queue_status and then releases the
 * command, dropping a TMR's ACK reference itself.
 */
static void fcsim_aborted_task(struct se_cmd *se_cmd)
{
	struct fcsim_cmd *cmd = to_cmd(se_cmd);
	unsigned long flags;

	if (se_cmd->se_cmd_flags & SCF_SCSI_TMR_CDB) {
		spin_lock_irqsave(&cmd->lock, flags);
		if (cmd->tmr_state != FCSIM_TMR_ABANDONED) {
			cmd->tmr_state = FCSIM_TMR_ABORTED;
			complete(&cmd->tmr_done);
		}
		spin_unlock_irqrestore(&cmd->lock, flags);
		return;
	}

	/* No status will be sent: don't let release_cmd report success. */
	fcsim_xchg_aborted(cmd);
}

/* ------------------------------------------------------------- TPG */

static char *fcsim_tpg_get_wwn(struct se_portal_group *se_tpg)
{
	return tpg_to_tport(se_tpg)->name;
}

static u16 fcsim_tpg_get_tag(struct se_portal_group *se_tpg)
{
	return FCSIM_TPGT;
}

/*
 * TPG attributes are written under fcsim_mutex but read locklessly by LIO,
 * which calls these with its own locks held.
 */
static int fcsim_check_demo_mode(struct se_portal_group *se_tpg)
{
	return READ_ONCE(tpg_to_tport(se_tpg)->attrib.generate_node_acls);
}

static int fcsim_check_demo_mode_cache(struct se_portal_group *se_tpg)
{
	return READ_ONCE(tpg_to_tport(se_tpg)->attrib.cache_dynamic_acls);
}

static int fcsim_check_demo_write_protect(struct se_portal_group *se_tpg)
{
	return READ_ONCE(tpg_to_tport(se_tpg)->attrib.demo_mode_write_protect);
}

static int fcsim_check_prod_write_protect(struct se_portal_group *se_tpg)
{
	return READ_ONCE(tpg_to_tport(se_tpg)->attrib.prod_mode_write_protect);
}

static int fcsim_check_demo_mode_login_only(struct se_portal_group *se_tpg)
{
	return READ_ONCE(tpg_to_tport(se_tpg)->attrib.demo_mode_login_only);
}

static struct se_portal_group *fcsim_make_tpg(struct se_wwn *wwn,
					      const char *name)
{
	struct fcsim_tport *tport = wwn_to_tport(wwn);
	int ret;

	/* Exactly "tpgt_1", not also "tpgt_01" or "tpgt_+1". */
	if (strcmp(name, "tpgt_" __stringify(FCSIM_TPGT))) {
		pr_err("%s: only tpgt_%d is supported\n", tport->name, FCSIM_TPGT);
		return ERR_PTR(-EINVAL);
	}

	tport->attrib = (struct fcsim_tpg_attrib) {
		.generate_node_acls	 = 1,
		.cache_dynamic_acls	 = 1,
		.demo_mode_write_protect = 1,
		.prod_mode_write_protect = 0,
		.demo_mode_login_only	 = 1,
	};

	ret = core_tpg_register(wwn, &tport->se_tpg, SCSI_PROTOCOL_FCP);
	if (ret < 0)
		return ERR_PTR(ret);

	mutex_lock(&fcsim_mutex);
	tport->tpg_registered = true;
	mutex_unlock(&fcsim_mutex);

	return &tport->se_tpg;
}

static int fcsim_enable_tpg(struct se_portal_group *se_tpg, bool enable)
{
	struct fcsim_tport *tport = tpg_to_tport(se_tpg);

	mutex_lock(&fcsim_mutex);
	tport->enabled = enable;
	mutex_unlock(&fcsim_mutex);

	pr_info("target port %s %s\n", tport->name,
		enable ? "enabled" : "disabled");
	fcsim_fabric_sync();
	return 0;
}

static void fcsim_drop_tpg(struct se_portal_group *se_tpg)
{
	struct fcsim_tport *tport = tpg_to_tport(se_tpg);

	mutex_lock(&fcsim_mutex);
	tport->enabled = false;
	tport->tpg_registered = false;
	mutex_unlock(&fcsim_mutex);

	/* Log out every initiator and drain the sessions before the TPG goes away. */
	fcsim_fabric_sync();
	fcsim_wait_drained(&tport->ndraining);

	mutex_lock(&fcsim_mutex);
	WARN_ON(!list_empty(&tport->nexus_list));
	mutex_unlock(&fcsim_mutex);

	core_tpg_deregister(se_tpg);
}

/* Explicit ACL created via configfs: its name must be a canonical WWPN. */
static int fcsim_init_nodeacl(struct se_node_acl *se_nacl, const char *name)
{
	u64 wwpn;

	if (fcsim_parse_wwn(name, &wwpn)) {
		pr_err("invalid initiator WWPN for ACL: %s (use xx:xx:...:xx)\n",
		       name);
		return -EINVAL;
	}
	/* An initiator that was refused before may log in now. */
	fcsim_fabric_kick();
	return 0;
}

/* ------------------------------------------------------------- TPG attrib */

#define DEF_FCSIM_TPG_ATTRIB(_name)					\
static ssize_t fcsim_tpg_attrib_##_name##_show(struct config_item *item,	\
					       char *page)		\
{									\
	struct fcsim_tport *tport = tpg_to_tport(attrib_to_tpg(item));	\
									\
	return sysfs_emit(page, "%d\n", READ_ONCE(tport->attrib._name));	\
}									\
									\
static ssize_t fcsim_tpg_attrib_##_name##_store(struct config_item *item, \
						const char *page,	\
						size_t count)		\
{									\
	struct fcsim_tport *tport = tpg_to_tport(attrib_to_tpg(item));	\
	bool val;							\
	int ret;							\
									\
	ret = kstrtobool(page, &val);					\
	if (ret)							\
		return ret;						\
	mutex_lock(&fcsim_mutex);					\
	WRITE_ONCE(tport->attrib._name, val);				\
	mutex_unlock(&fcsim_mutex);					\
	/* e.g. demo mode turned on: refused initiators may log in.	\
	 * Called by configfs alone (no LIO locks), so wait for it.	\
	 */								\
	fcsim_fabric_sync();						\
	return count;							\
}									\
CONFIGFS_ATTR(fcsim_tpg_attrib_, _name)

DEF_FCSIM_TPG_ATTRIB(generate_node_acls);
DEF_FCSIM_TPG_ATTRIB(cache_dynamic_acls);
DEF_FCSIM_TPG_ATTRIB(demo_mode_write_protect);
DEF_FCSIM_TPG_ATTRIB(prod_mode_write_protect);
DEF_FCSIM_TPG_ATTRIB(demo_mode_login_only);

static struct configfs_attribute *fcsim_tpg_attrib_attrs[] = {
	&fcsim_tpg_attrib_attr_generate_node_acls,
	&fcsim_tpg_attrib_attr_cache_dynamic_acls,
	&fcsim_tpg_attrib_attr_demo_mode_write_protect,
	&fcsim_tpg_attrib_attr_prod_mode_write_protect,
	&fcsim_tpg_attrib_attr_demo_mode_login_only,
	NULL,
};

/* ------------------------------------------------------------- WWN */

static struct se_wwn *fcsim_make_wwn(struct target_fabric_configfs *tf,
				     struct config_group *group,
				     const char *name)
{
	struct fcsim_tport *tport;
	u64 wwpn;
	int ret;

	if (fcsim_parse_wwn(name, &wwpn)) {
		pr_err("invalid target WWPN: %s (use xx:xx:...:xx)\n", name);
		return ERR_PTR(-EINVAL);
	}

	tport = kzalloc(sizeof(*tport), GFP_KERNEL);
	if (!tport)
		return ERR_PTR(-ENOMEM);

	INIT_LIST_HEAD(&tport->nexus_list);
	atomic_set(&tport->ndraining, 0);
	tport->wwpn = wwpn;
	tport->wwnn = fcsim_default_wwnn(wwpn);
	fcsim_format_wwn(tport->name, sizeof(tport->name), wwpn);

	mutex_lock(&fcsim_mutex);
	if (fcsim_wwpn_in_use(wwpn)) {
		ret = -EEXIST;
		goto out_unlock;
	}
	ret = fcsim_port_id_alloc(&tport->port_id);
	if (ret)
		goto out_unlock;
	list_add_tail(&tport->node, &fcsim_tports);
	mutex_unlock(&fcsim_mutex);

	pr_info("target port %s (port_id 0x%06x) created\n",
		tport->name, tport->port_id);
	return &tport->se_wwn;

out_unlock:
	mutex_unlock(&fcsim_mutex);
	kfree(tport);
	return ERR_PTR(ret);
}

static void fcsim_drop_wwn(struct se_wwn *wwn)
{
	struct fcsim_tport *tport = wwn_to_tport(wwn);

	mutex_lock(&fcsim_mutex);
	WARN_ON(!list_empty(&tport->nexus_list));
	list_del(&tport->node);
	fcsim_port_id_free(tport->port_id);
	mutex_unlock(&fcsim_mutex);

	pr_info("target port %s removed\n", tport->name);
	kfree(tport);
}

/*
 * Fabric-level attributes: LIO attaches tfc_wwn_attrs to the fabric
 * directory (/sys/kernel/config/target/fcsim/), not to each WWN.
 */
static ssize_t fcsim_wwn_version_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "%s\n", FCSIM_VERSION);
}

CONFIGFS_ATTR_RO(fcsim_wwn_, version);

static struct configfs_attribute *fcsim_wwn_attrs[] = {
	&fcsim_wwn_attr_version,
	NULL,
};

/* Per-port attributes live in tpgt_1/ (the only TPG of an FC port). */
static ssize_t fcsim_tpg_node_name_show(struct config_item *item, char *page)
{
	char buf[FCSIM_WWN_BUFLEN];

	fcsim_format_wwn(buf, sizeof(buf), tpg_to_tport(to_tpg(item))->wwnn);
	return sysfs_emit(page, "%s\n", buf);
}

static ssize_t fcsim_tpg_port_id_show(struct config_item *item, char *page)
{
	return sysfs_emit(page, "0x%06x\n", tpg_to_tport(to_tpg(item))->port_id);
}

/* Initiator ports currently logged in to this target port. */
static ssize_t fcsim_tpg_sessions_show(struct config_item *item, char *page)
{
	struct fcsim_tport *tport = tpg_to_tport(to_tpg(item));
	struct fcsim_nexus *nexus;
	unsigned int more = 0;
	ssize_t len = 0;

	mutex_lock(&fcsim_mutex);
	list_for_each_entry(nexus, &tport->nexus_list, tport_node)
		len = fcsim_emit_name(page, len, nexus->iport->name, &more);
	mutex_unlock(&fcsim_mutex);
	return fcsim_emit_more(page, len, more);
}

CONFIGFS_ATTR_RO(fcsim_tpg_, node_name);
CONFIGFS_ATTR_RO(fcsim_tpg_, port_id);
CONFIGFS_ATTR_RO(fcsim_tpg_, sessions);

static struct configfs_attribute *fcsim_tpg_base_attrs[] = {
	&fcsim_tpg_attr_node_name,
	&fcsim_tpg_attr_port_id,
	&fcsim_tpg_attr_sessions,
	NULL,
};

/* ------------------------------------------------------------- ops */

static const struct target_core_fabric_ops fcsim_ops = {
	.module				= THIS_MODULE,
	.fabric_name			= FCSIM_FABRIC_NAME,
	.node_acl_size			= sizeof(struct se_node_acl),
	.tpg_get_wwn			= fcsim_tpg_get_wwn,
	.tpg_get_tag			= fcsim_tpg_get_tag,
	.tpg_check_demo_mode		= fcsim_check_demo_mode,
	.tpg_check_demo_mode_cache	= fcsim_check_demo_mode_cache,
	.tpg_check_demo_mode_write_protect = fcsim_check_demo_write_protect,
	.tpg_check_prod_mode_write_protect = fcsim_check_prod_write_protect,
	.tpg_check_demo_mode_login_only	= fcsim_check_demo_mode_login_only,
	.check_stop_free		= fcsim_check_stop_free,
	.release_cmd			= fcsim_release_cmd,
	.close_session			= fcsim_close_session,
	.sess_get_index			= fcsim_sess_get_index,
	.write_pending			= fcsim_write_pending,
	.queue_data_in			= fcsim_queue_data_in,
	.queue_status			= fcsim_queue_status,
	.queue_tm_rsp			= fcsim_queue_tm_rsp,
	.aborted_task			= fcsim_aborted_task,
	.fabric_make_wwn		= fcsim_make_wwn,
	.fabric_drop_wwn		= fcsim_drop_wwn,
	.fabric_make_tpg		= fcsim_make_tpg,
	.fabric_enable_tpg		= fcsim_enable_tpg,
	.fabric_drop_tpg		= fcsim_drop_tpg,
	.fabric_init_nodeacl		= fcsim_init_nodeacl,
	.tfc_wwn_attrs			= fcsim_wwn_attrs,
	.tfc_tpg_base_attrs		= fcsim_tpg_base_attrs,
	.tfc_tpg_attrib_attrs		= fcsim_tpg_attrib_attrs,
	.default_submit_type		= TARGET_QUEUE_SUBMIT,
	.direct_submit_supp		= 0,
};

int fcsim_tgt_init(void)
{
	return target_register_template(&fcsim_ops);
}

void fcsim_tgt_exit(void)
{
	target_unregister_template(&fcsim_ops);
}

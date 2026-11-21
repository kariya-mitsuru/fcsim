// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: initiator side.
 *
 * Each iport is a Scsi_Host attached to scsi_transport_fc.  Commands are
 * handed straight to LIO (no data copy: the initiator's scatterlist is
 * passed through), the same way tcm_loop does it.
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/slab.h>
#include <linux/string.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/blk-mq.h>
#include <scsi/scsi.h>
#include <scsi/scsi_cmnd.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_host.h>
#include <scsi/scsi_tcq.h>
#include <scsi/scsi_transport_fc.h>
#include <target/target_core_fabric.h>

#include "fcsim.h"

static struct scsi_transport_template *fcsim_transport;

/* How long EH waits for the target side to release aborted/reset commands. */
#define FCSIM_EH_RELEASE_TMO	(30 * HZ)

static inline struct fcsim_iport *shost_to_iport(struct Scsi_Host *shost)
{
	return *(struct fcsim_iport **)shost_priv(shost);
}

/* ------------------------------------------------------------- I/O path */

/*
 * Final completion of an I/O command, once the target side no longer
 * references it.  If the command timed out, scsi_done() is a no-op and SCSI
 * EH owns it; EH waits for ->released and then for an RCU grace period, so
 * it cannot hand the command back to the midlayer (which may requeue it)
 * while this scsi_done() call is still in progress.
 */
void fcsim_cmd_done(struct fcsim_cmd *cmd)
{
	struct scsi_cmnd *sc = cmd->sc;

	rcu_read_lock();
	smp_store_release(&cmd->released, true);
	scsi_done(sc);
	rcu_read_unlock();
}

static bool fcsim_cmd_released(struct scsi_cmnd *sc)
{
	struct fcsim_cmd *cmd = scsi_cmd_priv(sc);

	return smp_load_acquire(&cmd->released);
}

struct fcsim_busy_iter {
	struct scsi_device	*sdev;
	bool			busy;
};

static bool fcsim_sdev_busy_fn(struct scsi_cmnd *sc, void *data)
{
	struct fcsim_busy_iter *it = data;

	if (sc->device == it->sdev && !fcsim_cmd_released(sc)) {
		it->busy = true;
		return false;
	}
	return true;
}

/* Are commands on @sdev still held by the target side? */
static bool fcsim_sdev_released(struct scsi_device *sdev)
{
	struct fcsim_busy_iter it = { .sdev = sdev };

	scsi_host_busy_iter(sdev->host, fcsim_sdev_busy_fn, &it);
	return !it.busy;
}

/*
 * Wait until @sc (or, with @sc == NULL, every command on @sdev) has been
 * released by the target side.  A TMR response alone does not guarantee
 * that: LIO takes a command off the device state list before it calls
 * release_cmd, and ABORT_TASK answers TASK_DOES_NOT_EXIST in between.
 */
static bool fcsim_eh_wait_released(struct scsi_device *sdev,
				   struct scsi_cmnd *sc, unsigned long tmo)
{
	unsigned long deadline = jiffies + tmo;

	for (;;) {
		if (sc ? fcsim_cmd_released(sc) : fcsim_sdev_released(sdev))
			break;
		if (time_after_eq(jiffies, deadline)) {
			sdev_printk(KERN_WARNING, sdev,
				    "target did not release %s\n",
				    sc ? "the aborted command" : "reset commands");
			return false;
		}
		msleep(10);
	}
	/* Wait for any fcsim_cmd_done() still inside scsi_done(). */
	synchronize_rcu();
	return true;
}

static int fcsim_queuecommand(struct Scsi_Host *shost, struct scsi_cmnd *sc)
{
	struct fcsim_iport *iport = shost_to_iport(shost);
	struct fc_rport *rport = starget_to_rport(scsi_target(sc->device));
	struct fcsim_cmd *cmd = scsi_cmd_priv(sc);
	struct se_cmd *se_cmd = &cmd->se_cmd;
	struct fcsim_nexus *nexus;
	int ret;

	memset(cmd, 0, sizeof(*cmd));
	cmd->sc = sc;

	if (!rport) {
		set_host_byte(sc, DID_NO_CONNECT);
		goto done;
	}
	ret = fc_remote_port_chkready(rport);
	if (ret) {
		sc->result = ret;
		goto done;
	}

	se_cmd->tag = blk_mq_unique_tag(scsi_cmd_to_rq(sc));

	rcu_read_lock();
	nexus = fcsim_nexus_lookup_rcu(iport, rport->port_name);
	if (!nexus) {
		rcu_read_unlock();
		/* Logout in progress; let the SCSI layer retry. */
		set_host_byte(sc, DID_TRANSPORT_DISRUPTED);
		goto done;
	}
	/* Takes a session command reference; fails once the session is stopped. */
	ret = target_init_cmd(se_cmd, nexus->se_sess, cmd->sense_buf,
			      sc->device->lun, scsi_bufflen(sc), TCM_SIMPLE_TAG,
			      sc->sc_data_direction, 0);
	rcu_read_unlock();
	if (ret) {
		set_host_byte(sc, DID_TRANSPORT_DISRUPTED);
		goto done;
	}

	/* On failure LIO has already queued CHECK CONDITION status. */
	if (target_submit_prep(se_cmd, sc->cmnd, scsi_sglist(sc),
			       scsi_sg_count(sc), NULL, 0, NULL, 0, GFP_ATOMIC))
		return 0;

	target_submit(se_cmd);
	return 0;

done:
	fcsim_cmd_done(cmd);
	return 0;
}

/* ------------------------------------------------------------- EH */

static int fcsim_issue_tmr(struct scsi_cmnd *sc, u64 tag,
			   enum tcm_tmreq_table tmr)
{
	struct fcsim_iport *iport = shost_to_iport(sc->device->host);
	struct fc_rport *rport = starget_to_rport(scsi_target(sc->device));
	struct fcsim_nexus *nexus;
	struct fcsim_cmd *cmd;
	int ret, rc = -ENODEV;

	if (!rport)
		return TMR_FUNCTION_FAILED;

	cmd = kzalloc(sizeof(*cmd), GFP_KERNEL);
	if (!cmd)
		return TMR_FUNCTION_FAILED;
	init_completion(&cmd->tmr_done);

	rcu_read_lock();
	nexus = fcsim_nexus_lookup_rcu(iport, rport->port_name);
	if (nexus)
		rc = target_submit_tmr(&cmd->se_cmd, nexus->se_sess,
				       cmd->sense_buf, sc->device->lun, NULL,
				       tmr, GFP_ATOMIC, tag,
				       TARGET_SCF_ACK_KREF);
	rcu_read_unlock();
	if (rc < 0) {
		kfree(cmd);
		return TMR_FUNCTION_FAILED;
	}

	wait_for_completion(&cmd->tmr_done);
	ret = cmd->se_cmd.se_tmr_req->response;
	/* Drops our ACK reference; release_cmd frees cmd. */
	target_put_sess_cmd(&cmd->se_cmd);
	return ret;
}

/*
 * Any result other than FAILED hands sc back to the midlayer, which may
 * requeue it right away (reusing the fcsim_cmd), so first make sure the
 * target side is completely done with it.
 */
static int fcsim_eh_abort(struct scsi_cmnd *sc)
{
	unsigned long tmo = 0;
	int ret;

	ret = fc_block_scsi_eh(sc);
	if (ret)	/* FAST_IO_FAIL */
		return fcsim_eh_wait_released(sc->device, sc,
					      FCSIM_EH_RELEASE_TMO) ? ret : FAILED;

	if (!fcsim_cmd_released(sc)) {
		ret = fcsim_issue_tmr(sc, blk_mq_unique_tag(scsi_cmd_to_rq(sc)),
				      TMR_ABORT_TASK);
		/*
		 * COMPLETE: LIO released it before answering.
		 * TASK_DOES_NOT_EXIST: completed, release may still be pending.
		 * Anything else: only succeed if it is already gone.
		 */
		if (ret == TMR_FUNCTION_COMPLETE || ret == TMR_TASK_DOES_NOT_EXIST)
			tmo = FCSIM_EH_RELEASE_TMO;
	}
	return fcsim_eh_wait_released(sc->device, sc, tmo) ? SUCCESS : FAILED;
}

static int fcsim_eh_device_reset(struct scsi_cmnd *sc)
{
	struct scsi_device *sdev = sc->device;
	int ret;

	ret = fc_block_scsi_eh(sc);
	if (ret)	/* FAST_IO_FAIL */
		return fcsim_eh_wait_released(sdev, NULL,
					      FCSIM_EH_RELEASE_TMO) ? ret : FAILED;

	ret = fcsim_issue_tmr(sc, 0, TMR_LUN_RESET);
	if (ret != TMR_FUNCTION_COMPLETE)
		return FAILED;
	/* EH now completes every failed command on this LUN. */
	return fcsim_eh_wait_released(sdev, NULL, FCSIM_EH_RELEASE_TMO) ?
		SUCCESS : FAILED;
}

static const struct scsi_host_template fcsim_sht = {
	.module			= THIS_MODULE,
	.name			= "tcm_fcsim virtual FC HBA",
	.proc_name		= FCSIM_NAME,
	.queuecommand		= fcsim_queuecommand,
	.eh_timed_out		= fc_eh_timed_out,
	.eh_abort_handler	= fcsim_eh_abort,
	.eh_device_reset_handler = fcsim_eh_device_reset,
	.change_queue_depth	= scsi_change_queue_depth,
	.this_id		= -1,
	.sg_tablesize		= 256,
	.max_sectors		= 0xFFFF,
	.dma_boundary		= PAGE_SIZE - 1,
	.track_queue_depth	= 1,
	.cmd_size		= sizeof(struct fcsim_cmd),
};

/* ------------------------------------------------------------- FC transport */

static void fcsim_set_rport_dev_loss_tmo(struct fc_rport *rport, u32 timeout)
{
	rport->dev_loss_tmo = timeout ? timeout : 1;
}

/*
 * issue_lip: retry logins that are missing (e.g. after ACL changes) and
 * rescan all logged-in targets for new LUNs.
 */
static int fcsim_issue_lip(struct Scsi_Host *shost)
{
	struct fcsim_iport *iport = shost_to_iport(shost);
	struct fc_rport **rports;
	struct fcsim_nexus *nexus;
	int i, n = 0, max = 0;

	fcsim_fabric_sync();

	mutex_lock(&fcsim_mutex);
	list_for_each_entry(nexus, &iport->nexus_list, iport_node)
		max++;
	rports = kcalloc(max ?: 1, sizeof(*rports), GFP_KERNEL);
	if (!rports) {
		mutex_unlock(&fcsim_mutex);
		return -ENOMEM;
	}
	list_for_each_entry(nexus, &iport->nexus_list, iport_node) {
		if (nexus->rport) {
			get_device(&nexus->rport->dev);
			rports[n++] = nexus->rport;
		}
	}
	mutex_unlock(&fcsim_mutex);

	/* Scan without holding fcsim_mutex: the scan I/O does not need it. */
	for (i = 0; i < n; i++) {
		if (rports[i]->scsi_target_id != -1)
			scsi_scan_target(&rports[i]->dev, rports[i]->channel,
					 rports[i]->scsi_target_id,
					 SCAN_WILD_CARD, SCSI_SCAN_RESCAN);
		put_device(&rports[i]->dev);
	}
	kfree(rports);
	return 0;
}

static struct fc_function_template fcsim_fc_functions = {
	.show_host_node_name		= 1,
	.show_host_port_name		= 1,
	.show_host_permanent_port_name	= 1,
	.show_host_supported_classes	= 1,
	.show_host_supported_fc4s	= 1,
	.show_host_supported_speeds	= 1,
	.show_host_maxframe_size	= 1,
	.show_host_serial_number	= 1,
	.show_host_manufacturer		= 1,
	.show_host_model		= 1,
	.show_host_model_description	= 1,
	.show_host_hardware_version	= 1,
	.show_host_driver_version	= 1,
	.show_host_firmware_version	= 1,
	.show_host_port_id		= 1,
	.show_host_port_type		= 1,
	.show_host_port_state		= 1,
	.show_host_active_fc4s		= 1,
	.show_host_speed		= 1,
	.show_host_fabric_name		= 1,
	.show_host_symbolic_name	= 1,

	.show_rport_maxframe_size	= 1,
	.show_rport_supported_classes	= 1,
	.show_rport_dev_loss_tmo	= 1,
	.set_rport_dev_loss_tmo		= fcsim_set_rport_dev_loss_tmo,

	.show_starget_node_name		= 1,
	.show_starget_port_name		= 1,
	.show_starget_port_id		= 1,

	.issue_fc_host_lip		= fcsim_issue_lip,
};

/* Caller holds fcsim_mutex (or the host is not yet visible). */
static void fcsim_fc_host_update_link(struct fcsim_iport *iport)
{
	struct Scsi_Host *shost = iport->shost;

	if (iport->link_up) {
		fc_host_port_state(shost) = FC_PORTSTATE_ONLINE;
		fc_host_speed(shost) = FC_PORTSPEED_32GBIT;
		fc_host_port_id(shost) = iport->port_id;
		fc_host_fabric_name(shost) = fcsim_fabric_wwn;
		fc_host_port_type(shost) = FC_PORTTYPE_NPORT;
	} else {
		fc_host_port_state(shost) = FC_PORTSTATE_LINKDOWN;
		fc_host_speed(shost) = FC_PORTSPEED_UNKNOWN;
		fc_host_port_id(shost) = 0;
		fc_host_fabric_name(shost) = 0;
		fc_host_port_type(shost) = FC_PORTTYPE_UNKNOWN;
	}
}

static void fcsim_fc_host_init(struct fcsim_iport *iport)
{
	struct Scsi_Host *shost = iport->shost;

	fc_host_node_name(shost) = iport->wwnn;
	fc_host_port_name(shost) = iport->wwpn;
	fc_host_permanent_port_name(shost) = iport->wwpn;
	fc_host_supported_classes(shost) = FC_COS_CLASS3;
	fc_host_maxframe_size(shost) = FCSIM_FRAME_SIZE;
	fc_host_supported_speeds(shost) = FC_PORTSPEED_8GBIT |
		FC_PORTSPEED_16GBIT | FC_PORTSPEED_32GBIT;

	/* FC-4 type 0x08 (FCP) -> bit 8 of the big-endian bitmap -> byte 2 */
	memset(fc_host_supported_fc4s(shost), 0, FC_FC4_LIST_SIZE);
	fc_host_supported_fc4s(shost)[2] = 1;
	memset(fc_host_active_fc4s(shost), 0, FC_FC4_LIST_SIZE);
	fc_host_active_fc4s(shost)[2] = 1;

	strscpy(fc_host_manufacturer(shost), "Linux tcm_fcsim",
		FC_SERIAL_NUMBER_SIZE);
	strscpy(fc_host_model(shost), "FCSIM-32G", FC_SYMBOLIC_NAME_SIZE);
	strscpy(fc_host_model_description(shost),
		"Software-only FC HBA for LIO", FC_SYMBOLIC_NAME_SIZE);
	snprintf(fc_host_serial_number(shost), FC_SERIAL_NUMBER_SIZE,
		 "FCSIM%06X", iport->port_id);
	strscpy(fc_host_hardware_version(shost), "1", FC_VERSION_STRING_SIZE);
	strscpy(fc_host_driver_version(shost), FCSIM_VERSION,
		FC_VERSION_STRING_SIZE);
	strscpy(fc_host_firmware_version(shost), FCSIM_VERSION,
		FC_VERSION_STRING_SIZE);
	snprintf(fc_host_symbolic_name(shost), FC_SYMBOLIC_NAME_SIZE,
		 "tcm_fcsim v%s port %s", FCSIM_VERSION, iport->name);

	fcsim_fc_host_update_link(iport);
}

/* ------------------------------------------------------------- iport */

struct fcsim_iport *fcsim_iport_create(u64 wwpn)
{
	struct fcsim_iport *iport;
	struct Scsi_Host *shost;
	int ret;

	iport = kzalloc(sizeof(*iport), GFP_KERNEL);
	if (!iport)
		return ERR_PTR(-ENOMEM);

	INIT_LIST_HEAD(&iport->nexus_list);
	iport->wwpn = wwpn;
	iport->wwnn = fcsim_default_wwnn(wwpn);
	iport->link_up = true;
	fcsim_format_wwn(iport->name, sizeof(iport->name), wwpn);

	mutex_lock(&fcsim_mutex);
	if (fcsim_wwpn_in_use(wwpn)) {
		ret = -EEXIST;
		goto out_unlock;
	}
	ret = fcsim_port_id_alloc(&iport->port_id);
	if (ret)
		goto out_unlock;
	mutex_unlock(&fcsim_mutex);

	shost = scsi_host_alloc(&fcsim_sht, sizeof(struct fcsim_iport *));
	if (!shost) {
		ret = -ENOMEM;
		goto out_port_id;
	}
	*(struct fcsim_iport **)shost_priv(shost) = iport;
	iport->shost = shost;

	shost->transportt = fcsim_transport;
	shost->max_channel = 0;
	shost->max_id = FCSIM_MAX_TARGET_IDS;
	shost->max_lun = FCSIM_MAX_LUN;
	shost->max_cmd_len = 16;
	shost->can_queue = 1024;
	shost->cmd_per_lun = 64;

	ret = scsi_add_host(shost, fcsim_root_dev);
	if (ret)
		goto out_put;

	/* fc_host data is allocated by scsi_add_host() via the transport. */
	fcsim_fc_host_init(iport);

	mutex_lock(&fcsim_mutex);
	list_add_tail(&iport->node, &fcsim_iports);
	mutex_unlock(&fcsim_mutex);

	pr_info("host%u: initiator port %s (port_id 0x%06x) created\n",
		shost->host_no, iport->name, iport->port_id);

	/* Log in to every online target port. */
	fcsim_fabric_sync();
	return iport;

out_put:
	scsi_host_put(shost);
out_port_id:
	mutex_lock(&fcsim_mutex);
	fcsim_port_id_free(iport->port_id);
out_unlock:
	mutex_unlock(&fcsim_mutex);
	kfree(iport);
	return ERR_PTR(ret);
}

/* Tears down everything except the iport memory (freed by configfs release). */
void fcsim_iport_destroy(struct fcsim_iport *iport)
{
	struct Scsi_Host *shost = iport->shost;

	mutex_lock(&fcsim_mutex);
	iport->removing = true;
	mutex_unlock(&fcsim_mutex);

	/* Log out of all targets. */
	fcsim_fabric_sync();

	mutex_lock(&fcsim_mutex);
	WARN_ON(!list_empty(&iport->nexus_list));
	list_del(&iport->node);
	fcsim_port_id_free(iport->port_id);
	mutex_unlock(&fcsim_mutex);

	pr_info("host%u: initiator port %s removed\n",
		shost->host_no, iport->name);

	fc_remove_host(shost);
	scsi_remove_host(shost);
	scsi_host_put(shost);
	iport->shost = NULL;
}

void fcsim_iport_set_link(struct fcsim_iport *iport, bool up)
{
	struct Scsi_Host *shost = iport->shost;

	mutex_lock(&fcsim_mutex);
	if (iport->link_up == up) {
		mutex_unlock(&fcsim_mutex);
		return;
	}
	iport->link_up = up;
	fcsim_fc_host_update_link(iport);
	mutex_unlock(&fcsim_mutex);

	pr_info("host%u: link %s\n", shost->host_no, up ? "up" : "down");
	fc_host_post_event(shost, fc_get_event_number(),
			   up ? FCH_EVT_LINKUP : FCH_EVT_LINKDOWN, 0);

	fcsim_fabric_sync();
}

int fcsim_iport_set_wwnn(struct fcsim_iport *iport, u64 wwnn)
{
	int ret = 0;

	mutex_lock(&fcsim_mutex);
	if (iport->link_up) {
		ret = -EBUSY;
	} else {
		iport->wwnn = wwnn;
		fc_host_node_name(iport->shost) = wwnn;
	}
	mutex_unlock(&fcsim_mutex);
	return ret;
}

/* ------------------------------------------------------------- rport */

/* Caller holds fcsim_mutex; process context. */
int fcsim_rport_add(struct fcsim_nexus *nexus)
{
	struct fcsim_tport *tport = nexus->tport;
	struct fc_rport_identifiers ids = {
		.node_name	= tport->wwnn,
		.port_name	= tport->wwpn,
		.port_id	= tport->port_id,
		.roles		= FC_PORT_ROLE_FCP_TARGET,
	};
	struct fc_rport *rport;

	rport = fc_remote_port_add(nexus->iport->shost, 0, &ids);
	if (!rport)
		return -ENOMEM;

	rport->maxframe_size = FCSIM_FRAME_SIZE;
	rport->supported_classes = FC_COS_CLASS3;
	nexus->rport = rport;
	return 0;
}

/* Caller holds fcsim_mutex. */
void fcsim_rport_delete(struct fcsim_nexus *nexus)
{
	if (!nexus->rport)
		return;
	fc_remote_port_delete(nexus->rport);
	nexus->rport = NULL;
}

/* ------------------------------------------------------------- init/exit */

int fcsim_ini_init(void)
{
	fcsim_transport = fc_attach_transport(&fcsim_fc_functions);
	if (!fcsim_transport)
		return -ENOMEM;
	return 0;
}

void fcsim_ini_exit(void)
{
	fc_release_transport(fcsim_transport);
}

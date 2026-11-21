// SPDX-License-Identifier: GPL-2.0
/*
 * tcm_fcsim: initiator side.
 *
 * Each iport is a Scsi_Host attached to scsi_transport_fc.  Every command
 * becomes an exchange (struct fcsim_cmd) that is handed to LIO; data is
 * copied between the scsi_cmnd and LIO's own buffers.  Like an HBA, the
 * initiator side can terminate an exchange at any time (EH,
 * terminate_rport_io, logout) and get the scsi_cmnd back, while LIO may
 * still be working on it.
 *
 * Between the two sits the fabric, which can delay or drop commands and
 * responses (fault injection, fcsim_fault.c).
 */
#define pr_fmt(fmt) "tcm_fcsim: " fmt

#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/blk-mq.h>
#include <scsi/scsi.h>
#include <scsi/scsi_cmnd.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_eh.h>
#include <scsi/scsi_host.h>
#include <scsi/scsi_tcq.h>
#include <scsi/scsi_transport.h>
#include <scsi/scsi_transport_fc.h>
#include <target/target_core_fabric.h>

#include "fcsim.h"

static struct scsi_transport_template *fcsim_transport;

static unsigned int tmr_timeout = 10;
module_param(tmr_timeout, uint, 0644);
MODULE_PARM_DESC(tmr_timeout,
		 "seconds SCSI EH waits for a task management response (default 10)");


static inline struct fcsim_iport *shost_to_iport(struct Scsi_Host *shost)
{
	return *(struct fcsim_iport **)shost_priv(shost);
}

/* ------------------------------------------------------------- exchanges */

static struct kmem_cache *fcsim_cmd_cache;

static void fcsim_cmd_ctor(void *obj)
{
	struct fcsim_cmd *cmd = obj;

	spin_lock_init(&cmd->lock);
}

static void fcsim_delay_timer_fn(struct timer_list *t);

static struct fcsim_cmd *fcsim_xchg_alloc(struct fcsim_iport *iport, gfp_t gfp)
{
	struct fcsim_cmd *cmd = kmem_cache_alloc(fcsim_cmd_cache, gfp);

	if (!cmd)
		return NULL;
	memset(&cmd->body, 0, sizeof(cmd->body));
	cmd->iport = iport;
	kref_init(&cmd->kref);
	INIT_LIST_HEAD(&cmd->held_node);
	timer_setup(&cmd->delay_timer, fcsim_delay_timer_fn, 0);
	init_completion(&cmd->tmr_done);
	return cmd;
}

static void fcsim_xchg_free(struct kref *kref)
{
	kmem_cache_free(fcsim_cmd_cache,
			container_of(kref, struct fcsim_cmd, kref));
}

void fcsim_xchg_put(struct fcsim_cmd *cmd)
{
	kref_put(&cmd->kref, fcsim_xchg_free);
}

/*
 * Copy @len bytes between two scatterlists.  Atomic context is fine (used
 * under the exchange lock).
 */
static void fcsim_sg_copy(struct scatterlist *dsg, unsigned int dnents,
			  struct scatterlist *ssg, unsigned int snents,
			  size_t len)
{
	struct sg_mapping_iter d, s;
	size_t doff = 0, soff = 0, n;
	bool dvalid = false, svalid = false;

	sg_miter_start(&d, dsg, dnents, SG_MITER_ATOMIC | SG_MITER_TO_SG);
	sg_miter_start(&s, ssg, snents, SG_MITER_ATOMIC | SG_MITER_FROM_SG);
	while (len) {
		if (!dvalid) {
			if (!sg_miter_next(&d))
				break;
			dvalid = true;
			doff = 0;
		}
		if (!svalid) {
			if (!sg_miter_next(&s))
				break;
			svalid = true;
			soff = 0;
		}
		n = min3(len, d.length - doff, s.length - soff);
		memcpy(d.addr + doff, s.addr + soff, n);
		doff += n;
		soff += n;
		len -= n;
		if (doff == d.length)
			dvalid = false;
		if (soff == s.length)
			svalid = false;
	}
	sg_miter_stop(&s);
	sg_miter_stop(&d);
}

/*
 * Complete the attached scsi_cmnd and detach it.  @host_byte < 0 keeps the
 * result set by the target side.  Caller holds cmd->lock (taken with
 * @flags) and cmd->sc != NULL; the lock is dropped.
 *
 * scsi_done() runs inside an RCU read section: SCSI EH, when it finds an
 * exchange already detached, waits for a grace period before handing the
 * scsi_cmnd back to the midlayer (which may requeue it at once).
 */
static void fcsim_xchg_finish(struct fcsim_cmd *cmd, unsigned long flags,
			      int host_byte)
{
	struct scsi_cmnd *sc = cmd->sc;
	struct fcsim_scmd *p = scsi_cmd_priv(sc);
	bool held = cmd->held;

	if (host_byte >= 0) {
		sc->result = 0;
		set_host_byte(sc, host_byte);
	}
	cmd->sc = NULL;
	WRITE_ONCE(p->cmd, NULL);
	if (held) {
		spin_lock(&cmd->iport->held_lock);
		list_del_init(&cmd->held_node);
		cmd->held = false;
		spin_unlock(&cmd->iport->held_lock);
	}

	rcu_read_lock();
	spin_unlock_irqrestore(&cmd->lock, flags);
	if (held)
		timer_delete_sync(&cmd->delay_timer);
	scsi_done(sc);
	rcu_read_unlock();

	fcsim_xchg_put(cmd);		/* the SCSI side's reference */
}

/* The exchange still attached to @sc, locked; or NULL. */
static struct fcsim_cmd *fcsim_xchg_lock_sc(struct scsi_cmnd *sc,
					    unsigned long *flags)
{
	struct fcsim_scmd *p = scsi_cmd_priv(sc);
	struct fcsim_cmd *cmd;

	rcu_read_lock();
	cmd = READ_ONCE(p->cmd);
	if (cmd) {
		spin_lock_irqsave(&cmd->lock, *flags);
		/* TYPESAFE_BY_RCU: it may have been freed and reused. */
		if (cmd->sc != sc) {
			spin_unlock_irqrestore(&cmd->lock, *flags);
			cmd = NULL;
		}
	}
	rcu_read_unlock();
	return cmd;
}

/* Terminate the exchange of @sc, if it still has one. */
static void fcsim_terminate_sc(struct scsi_cmnd *sc, int host_byte)
{
	struct fcsim_cmd *cmd;
	unsigned long flags;

	cmd = fcsim_xchg_lock_sc(sc, &flags);
	if (cmd)
		fcsim_xchg_finish(cmd, flags, host_byte);
}

/* Which commands to terminate. */
struct fcsim_scope {
	struct scsi_device	*sdev;
	struct scsi_target	*starget;
	struct fc_rport		*rport;
	u64			tport_wwpn;
	int			host_byte;
	unsigned int		count;
};

static bool fcsim_terminate_fn(struct scsi_cmnd *sc, void *data)
{
	struct fcsim_scope *s = data;
	struct fcsim_cmd *cmd;
	unsigned long flags;

	if (s->sdev && sc->device != s->sdev)
		return true;
	if (s->starget && scsi_target(sc->device) != s->starget)
		return true;
	if (s->rport) {
		/* starget_to_rport() is an unparenthesized ?: expression. */
		struct fc_rport *rport = starget_to_rport(scsi_target(sc->device));

		if (rport != s->rport)
			return true;
	}

	cmd = fcsim_xchg_lock_sc(sc, &flags);
	if (!cmd)
		return true;
	if (s->tport_wwpn && cmd->tport_wwpn != s->tport_wwpn) {
		spin_unlock_irqrestore(&cmd->lock, flags);
		return true;
	}
	fcsim_xchg_finish(cmd, flags, s->host_byte);
	s->count++;
	return true;
}

/*
 * Terminate every exchange in @s and give the scsi_cmnds back.  Whatever
 * LIO still does with them is no longer reported.  Process context.
 */
static unsigned int fcsim_terminate(struct Scsi_Host *shost,
				    struct fcsim_scope *s)
{
	scsi_host_busy_iter(shost, fcsim_terminate_fn, s);
	/* Wait out a concurrent normal completion still inside scsi_done(). */
	synchronize_rcu();
	return s->count;
}

/* Logout: every open exchange of the login is gone; the midlayer retries. */
void fcsim_terminate_tport(struct fcsim_iport *iport, u64 tport_wwpn)
{
	struct fcsim_scope s = {
		.tport_wwpn	= tport_wwpn,
		.host_byte	= DID_TRANSPORT_DISRUPTED,
	};

	fcsim_terminate(iport->shost, &s);
}

/* ------------------------------------------------------------- LIO hooks */

/* write_pending: fetch the WRITE data.  False if the exchange is gone. */
bool fcsim_xchg_fetch_write_data(struct fcsim_cmd *cmd)
{
	struct se_cmd *se_cmd = &cmd->se_cmd;
	unsigned long flags;
	bool ok = false;

	spin_lock_irqsave(&cmd->lock, flags);
	if (cmd->sc) {
		fcsim_sg_copy(se_cmd->t_data_sg, se_cmd->t_data_nents,
			      scsi_sglist(cmd->sc), scsi_sg_count(cmd->sc),
			      min(se_cmd->data_length, scsi_bufflen(cmd->sc)));
		ok = true;
	}
	spin_unlock_irqrestore(&cmd->lock, flags);
	return ok;
}

/* queue_data_in / queue_status: report data and status if still attached. */
void fcsim_xchg_status(struct fcsim_cmd *cmd, bool data_in)
{
	struct se_cmd *se_cmd = &cmd->se_cmd;
	struct scsi_cmnd *sc;
	unsigned long flags;

	spin_lock_irqsave(&cmd->lock, flags);
	sc = cmd->sc;
	if (!sc)
		goto out;

	if (data_in && se_cmd->t_data_sg)
		fcsim_sg_copy(scsi_sglist(sc), scsi_sg_count(sc),
			      se_cmd->t_data_sg, se_cmd->t_data_nents,
			      min(se_cmd->data_length, scsi_bufflen(sc)));

	if (se_cmd->sense_buffer &&
	    (se_cmd->se_cmd_flags & (SCF_TRANSPORT_TASK_SENSE |
				     SCF_EMULATED_TASK_SENSE))) {
		memcpy(sc->sense_buffer, se_cmd->sense_buffer,
		       SCSI_SENSE_BUFFERSIZE);
		sc->result = SAM_STAT_CHECK_CONDITION;
	} else {
		sc->result = data_in ? SAM_STAT_GOOD : se_cmd->scsi_status;
	}
	set_host_byte(sc, DID_OK);
	if (se_cmd->se_cmd_flags & (SCF_OVERFLOW_BIT | SCF_UNDERFLOW_BIT))
		scsi_set_resid(sc, se_cmd->residual_count);
out:
	spin_unlock_irqrestore(&cmd->lock, flags);
}

/* aborted_task: no status will be sent for this command. */
void fcsim_xchg_aborted(struct fcsim_cmd *cmd)
{
	unsigned long flags;

	spin_lock_irqsave(&cmd->lock, flags);
	if (cmd->sc) {
		cmd->sc->result = 0;
		set_host_byte(cmd->sc, DID_RESET);
	}
	spin_unlock_irqrestore(&cmd->lock, flags);
}

static void fcsim_hold_locked(struct fcsim_cmd *cmd, u32 delay_ms)
{
	struct fcsim_iport *iport = cmd->iport;

	spin_lock(&iport->held_lock);
	cmd->held = true;
	list_add_tail(&cmd->held_node, &iport->held_list);
	if (delay_ms)
		mod_timer(&cmd->delay_timer, jiffies + msecs_to_jiffies(delay_ms));
	spin_unlock(&iport->held_lock);
}

/* release_cmd: LIO is done with the exchange. */
void fcsim_xchg_released(struct fcsim_cmd *cmd)
{
	unsigned long flags;

	spin_lock_irqsave(&cmd->lock, flags);
	if (!cmd->sc) {
		spin_unlock_irqrestore(&cmd->lock, flags);
	} else if (cmd->drop_rsp) {
		/* Fault: the response never arrives; EH has to deal with it. */
		fcsim_hold_locked(cmd, 0);
		spin_unlock_irqrestore(&cmd->lock, flags);
	} else {
		fcsim_xchg_finish(cmd, flags, -1);
	}
	fcsim_xchg_put(cmd);		/* LIO's reference */
}

/* ------------------------------------------------------------- I/O path */

/*
 * Hand an exchange to LIO.  Any context.  The caller holds a reference of
 * its own: the exchange may be terminated (and the SCSI side's reference
 * dropped) concurrently.
 */
static void fcsim_deliver(struct fcsim_cmd *cmd)
{
	struct se_cmd *se_cmd = &cmd->se_cmd;
	struct fcsim_nexus *nexus;
	unsigned long flags;
	int ret = -ENOTCONN;

	if (!READ_ONCE(cmd->sc))	/* terminated before it left the HBA */
		return;

	rcu_read_lock();
	nexus = fcsim_nexus_lookup_rcu(cmd->iport, cmd->tport_wwpn);
	/* Takes a session command reference; fails once the session is stopped. */
	if (nexus)
		ret = target_init_cmd(se_cmd, nexus->se_sess, cmd->sense_buf,
				      cmd->lun, cmd->data_len, TCM_SIMPLE_TAG,
				      cmd->dir, 0);
	rcu_read_unlock();

	spin_lock_irqsave(&cmd->lock, flags);
	if (ret) {
		/* Logout in progress; let the SCSI layer retry. */
		if (cmd->sc)
			fcsim_xchg_finish(cmd, flags, DID_TRANSPORT_DISRUPTED);
		else
			spin_unlock_irqrestore(&cmd->lock, flags);
		return;
	}
	cmd->lio = true;
	kref_get(&cmd->kref);		/* LIO's reference */
	spin_unlock_irqrestore(&cmd->lock, flags);

	/*
	 * LIO allocates its own data buffers.  On failure it has already
	 * queued CHECK CONDITION status.  Either way the exchange may be gone
	 * by the time these return.
	 */
	if (target_submit_prep(se_cmd, cmd->cdb, NULL, 0, NULL, 0, NULL, 0,
			       GFP_ATOMIC))
		return;
	target_submit(se_cmd);
}

static void fcsim_delay_timer_fn(struct timer_list *t)
{
	struct fcsim_cmd *cmd = timer_container_of(cmd, t, delay_timer);
	struct fcsim_iport *iport = cmd->iport;
	unsigned long flags;

	spin_lock_irqsave(&iport->held_lock, flags);
	if (!cmd->held) {		/* terminated meanwhile */
		spin_unlock_irqrestore(&iport->held_lock, flags);
		return;
	}
	list_del_init(&cmd->held_node);
	cmd->held = false;
	kref_get(&cmd->kref);	/* still attached, so the SCSI ref is alive */
	spin_unlock_irqrestore(&iport->held_lock, flags);

	fcsim_deliver(cmd);
	fcsim_xchg_put(cmd);
}

static void fcsim_inject_error(struct scsi_cmnd *sc, enum fcsim_error err)
{
	sc->result = 0;
	switch (err) {
	case FCSIM_ERR_TRANSPORT:
		set_host_byte(sc, DID_ERROR);
		break;
	case FCSIM_ERR_BUSY:
		sc->result = SAM_STAT_BUSY;
		break;
	case FCSIM_ERR_QFULL:
		sc->result = SAM_STAT_TASK_SET_FULL;
		break;
	case FCSIM_ERR_MEDIUM:
		scsi_build_sense(sc, 0, MEDIUM_ERROR, 0x11, 0x00);
		break;
	case FCSIM_ERR_ABORTED:
		scsi_build_sense(sc, 0, ABORTED_COMMAND, 0x00, 0x00);
		break;
	case FCSIM_ERR_NONE:
		break;
	}
}

static int fcsim_queuecommand(struct Scsi_Host *shost, struct scsi_cmnd *sc)
{
	struct fcsim_iport *iport = shost_to_iport(shost);
	struct fc_rport *rport = starget_to_rport(scsi_target(sc->device));
	struct fcsim_scmd *p = scsi_cmd_priv(sc);
	struct fcsim_fault_action act;
	struct fcsim_cmd *cmd;
	unsigned long flags;
	int ret;

	p->cmd = NULL;
	if (!rport) {
		set_host_byte(sc, DID_NO_CONNECT);
		scsi_done(sc);
		return 0;
	}
	ret = fc_remote_port_chkready(rport);
	if (ret) {
		sc->result = ret;
		scsi_done(sc);
		return 0;
	}

	if (fcsim_fault_eval(iport, rport->port_name, false, &act) && act.error) {
		/* The fabric answers right away; nothing reaches the target. */
		fcsim_inject_error(sc, act.error);
		scsi_done(sc);
		return 0;
	}

	cmd = fcsim_xchg_alloc(iport, GFP_ATOMIC);
	if (!cmd)
		return SCSI_MLQUEUE_HOST_BUSY;
	cmd->sc = sc;
	cmd->tport_wwpn = rport->port_name;
	cmd->lun = sc->device->lun;
	cmd->tag = blk_mq_unique_tag(scsi_cmd_to_rq(sc));
	cmd->se_cmd.tag = cmd->tag;
	cmd->data_len = scsi_bufflen(sc);
	cmd->dir = sc->sc_data_direction;
	memcpy(cmd->cdb, sc->cmnd, min_t(unsigned int, sc->cmd_len,
					 sizeof(cmd->cdb)));
	cmd->drop_rsp = act.drop == FCSIM_DROP_RSP;

	/* Once published, EH or a logout may terminate it at any time. */
	kref_get(&cmd->kref);
	WRITE_ONCE(p->cmd, cmd);

	if (act.drop == FCSIM_DROP_CMD || act.delay_ms) {
		spin_lock_irqsave(&cmd->lock, flags);
		if (cmd->sc)
			fcsim_hold_locked(cmd, act.drop == FCSIM_DROP_CMD ?
					  0 : act.delay_ms);
		spin_unlock_irqrestore(&cmd->lock, flags);
	} else {
		fcsim_deliver(cmd);
	}
	fcsim_xchg_put(cmd);
	return 0;
}

/* ------------------------------------------------------------- EH */

/*
 * Send a TMR and wait (bounded) for the response.  Returns the TMR response,
 * or TMR_FUNCTION_FAILED when there is none.
 */
static int fcsim_issue_tmr(struct scsi_device *sdev, u64 tag,
			   enum tcm_tmreq_table tmr)
{
	struct fcsim_iport *iport = shost_to_iport(sdev->host);
	struct fc_rport *rport = starget_to_rport(scsi_target(sdev));
	unsigned long tmo = READ_ONCE(tmr_timeout) * HZ;
	struct fcsim_fault_action act;
	struct fcsim_nexus *nexus;
	struct fcsim_cmd *cmd;
	unsigned long flags;
	int ret, rc = -ENODEV;
	u8 state;

	if (!rport)
		return TMR_FUNCTION_FAILED;

	if (fcsim_fault_eval(iport, rport->port_name, true, &act) &&
	    act.drop != FCSIM_DROP_NONE) {
		/* The fabric loses the TMF: nobody ever answers it. */
		sdev_printk(KERN_INFO, sdev, "fault: dropping TMR %d\n", tmr);
		schedule_timeout_uninterruptible(tmo);
		return TMR_FUNCTION_FAILED;
	}

	cmd = fcsim_xchg_alloc(iport, GFP_KERNEL);	/* EH's reference */
	if (!cmd)
		return TMR_FUNCTION_FAILED;
	kref_get(&cmd->kref);				/* LIO's, see release_cmd */

	rcu_read_lock();
	nexus = fcsim_nexus_lookup_rcu(iport, rport->port_name);
	if (nexus)
		rc = target_submit_tmr(&cmd->se_cmd, nexus->se_sess,
				       cmd->sense_buf, sdev->lun, NULL,
				       tmr, GFP_ATOMIC, tag,
				       TARGET_SCF_ACK_KREF);
	rcu_read_unlock();
	if (rc < 0) {
		kmem_cache_free(fcsim_cmd_cache, cmd);
		return TMR_FUNCTION_FAILED;
	}

	wait_for_completion_timeout(&cmd->tmr_done, tmo);

	spin_lock_irqsave(&cmd->lock, flags);
	state = cmd->tmr_state;
	if (state == FCSIM_TMR_PENDING)
		cmd->tmr_state = FCSIM_TMR_ABANDONED;
	spin_unlock_irqrestore(&cmd->lock, flags);

	switch (state) {
	case FCSIM_TMR_RESPONDED:
		ret = cmd->se_cmd.se_tmr_req->response;
		target_put_sess_cmd(&cmd->se_cmd);	/* our ACK reference */
		break;
	case FCSIM_TMR_ABORTED:
		ret = TMR_FUNCTION_REJECTED;
		break;
	default:
		sdev_printk(KERN_WARNING, sdev,
			    "no response to TMR %d within %us\n", tmr,
			    jiffies_to_msecs(tmo) / 1000);
		ret = TMR_FUNCTION_FAILED;
		break;
	}
	fcsim_xchg_put(cmd);
	return ret;
}

/*
 * Like an HBA, EH terminates exchanges instead of waiting for the target:
 * once a handler returns, the scsi_cmnds are back with the midlayer and
 * anything LIO still reports for them is dropped.
 */
static int fcsim_eh_abort(struct scsi_cmnd *sc)
{
	struct fcsim_cmd *cmd;
	unsigned long flags;
	bool in_lio;
	int ret;

	ret = fc_block_scsi_eh(sc);
	if (ret) {			/* FAST_IO_FAIL */
		fcsim_terminate_sc(sc, DID_TRANSPORT_FAILFAST);
		synchronize_rcu();
		return ret;
	}

	cmd = fcsim_xchg_lock_sc(sc, &flags);
	if (!cmd) {
		/* Completed meanwhile: wait out its scsi_done() call. */
		synchronize_rcu();
		return SUCCESS;
	}
	in_lio = cmd->lio;
	if (!in_lio) {
		/* Still held by the fabric (delayed / dropped). */
		fcsim_xchg_finish(cmd, flags, DID_ABORT);
		return SUCCESS;
	}
	spin_unlock_irqrestore(&cmd->lock, flags);

	/* ABTS: the target must confirm, otherwise escalate. */
	ret = fcsim_issue_tmr(sc->device, blk_mq_unique_tag(scsi_cmd_to_rq(sc)),
			      TMR_ABORT_TASK);
	if (ret != TMR_FUNCTION_COMPLETE && ret != TMR_TASK_DOES_NOT_EXIST)
		return FAILED;

	fcsim_terminate_sc(sc, DID_ABORT);
	synchronize_rcu();
	return SUCCESS;
}

static int fcsim_eh_device_reset(struct scsi_cmnd *sc)
{
	struct fcsim_scope s = { .sdev = sc->device, .host_byte = DID_RESET };
	int ret;

	ret = fc_block_scsi_eh(sc);
	if (ret) {
		s.host_byte = DID_TRANSPORT_FAILFAST;
		fcsim_terminate(sc->device->host, &s);
		return ret;
	}

	ret = fcsim_issue_tmr(sc->device, 0, TMR_LUN_RESET);
	if (ret != TMR_FUNCTION_COMPLETE)
		return FAILED;
	fcsim_terminate(sc->device->host, &s);
	return SUCCESS;
}

static void fcsim_lun_reset_fn(struct scsi_device *sdev, void *data)
{
	int *failed = data;

	if (fcsim_issue_tmr(sdev, 0, TMR_LUN_RESET) != TMR_FUNCTION_COMPLETE)
		(*failed)++;
}

/*
 * LIO rejects TARGET RESET task management functions, so reset every LUN
 * behind the target port instead.
 */
static int fcsim_eh_target_reset(struct scsi_cmnd *sc)
{
	struct scsi_target *starget = scsi_target(sc->device);
	struct fcsim_scope s = { .starget = starget, .host_byte = DID_RESET };
	int ret, failed = 0;

	ret = fc_block_scsi_eh(sc);
	if (ret) {
		s.host_byte = DID_TRANSPORT_FAILFAST;
		fcsim_terminate(sc->device->host, &s);
		return ret;
	}

	starget_for_each_device(starget, &failed, fcsim_lun_reset_fn);
	if (failed)
		return FAILED;
	fcsim_terminate(sc->device->host, &s);
	return SUCCESS;
}

/*
 * HBA reset: every exchange of this port is terminated, wherever it is.
 * Logins are kept, so the TEST UNIT READY that EH sends next gets through.
 */
static int fcsim_eh_host_reset(struct scsi_cmnd *sc)
{
	struct Scsi_Host *shost = sc->device->host;
	struct fcsim_scope s = { .host_byte = DID_RESET };

	fcsim_terminate(shost, &s);
	shost_printk(KERN_INFO, shost,
		     "host reset: terminated %u exchange(s)\n", s.count);
	return SUCCESS;
}

static const struct scsi_host_template fcsim_sht = {
	.module			= THIS_MODULE,
	.name			= "tcm_fcsim virtual FC HBA",
	.proc_name		= FCSIM_NAME,
	.queuecommand		= fcsim_queuecommand,
	.eh_timed_out		= fc_eh_timed_out,
	.eh_abort_handler	= fcsim_eh_abort,
	.eh_device_reset_handler = fcsim_eh_device_reset,
	.eh_target_reset_handler = fcsim_eh_target_reset,
	.eh_host_reset_handler	= fcsim_eh_host_reset,
	.change_queue_depth	= scsi_change_queue_depth,
	.this_id		= -1,
	.sg_tablesize		= 256,
	.max_sectors		= 0xFFFF,
	.dma_boundary		= PAGE_SIZE - 1,
	.track_queue_depth	= 1,
	.cmd_size		= sizeof(struct fcsim_scmd),
};

/* ------------------------------------------------------------- FC transport */

static void fcsim_set_rport_dev_loss_tmo(struct fc_rport *rport, u32 timeout)
{
	rport->dev_loss_tmo = timeout ? timeout : 1;
}

/*
 * fast_io_fail_tmo / dev_loss_tmo expired on a blocked rport: give back
 * every exchange still open to it, as an HBA aborts them.
 */
static void fcsim_terminate_rport_io(struct fc_rport *rport)
{
	struct fcsim_scope s = {
		.rport		= rport,
		.host_byte	= DID_TRANSPORT_FAILFAST,
	};

	fcsim_terminate(rport_to_shost(rport), &s);
}

/*
 * issue_lip: retry logins that are missing (e.g. after ACL changes) and
 * rescan the online targets for new LUNs.
 */
static int fcsim_issue_lip(struct Scsi_Host *shost)
{
	fcsim_fabric_sync();
	/* fc_user_scan(): only rports that are online, under host_lock. */
	return shost->transportt->user_scan(shost, SCAN_WILD_CARD,
					    SCAN_WILD_CARD, SCAN_WILD_CARD);
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
	.terminate_rport_io		= fcsim_terminate_rport_io,

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

/* RSCN for @port_id (a target port joined or left the fabric). */
void fcsim_post_rscn(struct fcsim_iport *iport, u32 port_id)
{
	pr_debug("host%u: RSCN 0x%06x\n", iport->shost->host_no, port_id);
	fc_host_post_event(iport->shost, fc_get_event_number(), FCH_EVT_RSCN,
			   port_id);
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
	INIT_LIST_HEAD(&iport->draining_list);
	INIT_LIST_HEAD(&iport->refused_list);
	INIT_LIST_HEAD(&iport->held_list);
	INIT_LIST_HEAD(&iport->faults);
	spin_lock_init(&iport->held_lock);
	atomic_set(&iport->ndraining, 0);
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

	/* Log out of all targets and wait for the sessions to drain. */
	fcsim_fabric_sync();
	fcsim_wait_drained(&iport->ndraining);
	/* Whatever the fabric still holds (dropped commands) is lost too. */
	{
		struct fcsim_scope s = { .host_byte = DID_NO_CONNECT };

		fcsim_terminate(shost, &s);
	}

	mutex_lock(&fcsim_mutex);
	WARN_ON(!list_empty(&iport->nexus_list));
	fcsim_forget_refusals(iport, NULL);
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
	fcsim_cmd_cache = kmem_cache_create("fcsim_cmd", sizeof(struct fcsim_cmd),
					    0, SLAB_TYPESAFE_BY_RCU,
					    fcsim_cmd_ctor);
	if (!fcsim_cmd_cache)
		return -ENOMEM;

	fcsim_transport = fc_attach_transport(&fcsim_fc_functions);
	if (!fcsim_transport) {
		kmem_cache_destroy(fcsim_cmd_cache);
		return -ENOMEM;
	}
	return 0;
}

void fcsim_ini_exit(void)
{
	fc_release_transport(fcsim_transport);
	/* Exchanges may still be in RCU-delayed slab freeing. */
	rcu_barrier();
	kmem_cache_destroy(fcsim_cmd_cache);
}

/* SPDX-License-Identifier: GPL-2.0 */
/*
 * tcm_fcsim - software-only Fibre Channel SCSI loopback on top of LIO
 *
 * Initiator side: a SCSI LLD registered with scsi_transport_fc, so
 * /sys/class/fc_host, fc_remote_ports and fc_transport show up as with a
 * real HBA.  Target side: a LIO fabric module ("fcsim"), so LUNs and ACLs
 * are managed with targetcli.  Both are connected by a virtual fabric
 * inside this module.
 */
#ifndef _TCM_FCSIM_H
#define _TCM_FCSIM_H

#include <linux/types.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/completion.h>
#include <linux/configfs.h>
#include <linux/rcupdate.h>
#include <linux/spinlock.h>
#include <linux/timer.h>
#include <linux/kref.h>
#include <linux/workqueue.h>
#include <linux/atomic.h>
#include <target/target_core_base.h>

#define FCSIM_VERSION		"0.1"
#define FCSIM_NAME		"tcm_fcsim"
#define FCSIM_FABRIC_NAME	"fcsim"

/* "xx:xx:xx:xx:xx:xx:xx:xx" */
#define FCSIM_WWN_STRLEN	23
#define FCSIM_WWN_BUFLEN	(FCSIM_WWN_STRLEN + 1)

#define FCSIM_FRAME_SIZE	2048
#define FCSIM_DOMAIN_ID		0x01
#define FCSIM_MAX_PORTS		254	/* area 1..254 of domain 0x01 */
#define FCSIM_MAX_TARGET_IDS	4096
#define FCSIM_MAX_LUN		65536
#define FCSIM_TPGT		1	/* FC ports have exactly one TPG */

struct Scsi_Host;
struct fc_rport;
struct scsi_cmnd;

/* Logged-in (iport, tport) pair: the I_T nexus. */
struct fcsim_nexus {
	struct list_head	iport_node;	/* iport->nexus_list (RCU readers) */
	struct list_head	tport_node;	/* tport->nexus_list */
	struct fcsim_iport	*iport;
	struct fcsim_tport	*tport;
	u64			tport_wwpn;	/* lookup key for the I/O path */
	struct se_session	*se_sess;
	struct fc_rport		*rport;		/* valid while logged in */
	u32			index;
	bool			closing;	/* LIO asked us to close it */
	/* Signalled when LIO's close_session() no longer touches us. */
	struct completion	close_done;
	/* Logged out: the session is drained outside fcsim_mutex. */
	struct work_struct	drain_work;
	struct list_head	drain_node;	/* iport->draining_list */
};

/* Fault injection actions (see fcsim_fault.c). */
enum fcsim_drop {
	FCSIM_DROP_NONE,
	FCSIM_DROP_CMD,		/* command never reaches the target */
	FCSIM_DROP_RSP,		/* target executes it, response is lost */
};

enum fcsim_error {
	FCSIM_ERR_NONE,
	FCSIM_ERR_TRANSPORT,	/* DID_ERROR */
	FCSIM_ERR_BUSY,		/* SAM_STAT_BUSY */
	FCSIM_ERR_QFULL,	/* SAM_STAT_TASK_SET_FULL */
	FCSIM_ERR_MEDIUM,	/* CHECK CONDITION, MEDIUM ERROR 11/00 */
	FCSIM_ERR_ABORTED,	/* CHECK CONDITION, ABORTED COMMAND 00/00 */
};

struct fcsim_fault_action {
	u32			delay_ms;
	enum fcsim_drop		drop;
	enum fcsim_error	error;
};

/* Initiator port: one virtual HBA port = one Scsi_Host. */
struct fcsim_iport {
	struct list_head	node;		/* fcsim_iports */
	struct config_group	group;		/* /sys/kernel/config/fcsim/hosts/<wwpn> */
	struct config_group	faults_group;	/* .../hosts/<wwpn>/faults */
	struct Scsi_Host	*shost;
	u64			wwpn;
	u64			wwnn;
	u32			port_id;
	bool			link_up;
	bool			removing;
	struct list_head	nexus_list;
	struct list_head	draining_list;	/* logged out, session not yet drained */
	struct list_head	refused_list;	/* logins the target refused (fcsim_main.c) */
	atomic_t		ndraining;	/* logged-out sessions still draining */

	/* Commands held by the fabric (delayed / dropped), see fcsim_ini.c. */
	spinlock_t		held_lock;
	struct list_head	held_list;
	struct list_head	faults;		/* fcsim_fault rules (RCU, held_lock) */

	char			name[FCSIM_WWN_BUFLEN];
};

struct fcsim_tpg_attrib {
	int			generate_node_acls;
	int			cache_dynamic_acls;
	int			demo_mode_write_protect;
	int			prod_mode_write_protect;
	int			demo_mode_login_only;
};

/* Target port: one LIO WWN with its single tpgt_1. */
struct fcsim_tport {
	struct list_head	node;		/* fcsim_tports */
	u64			wwpn;
	u64			wwnn;
	u32			port_id;
	bool			tpg_registered;
	bool			enabled;
	bool			rscn_online;	/* online state last announced by RSCN */
	struct list_head	nexus_list;
	atomic_t		ndraining;
	struct fcsim_tpg_attrib	attrib;
	struct se_portal_group	se_tpg;
	struct se_wwn		se_wwn;
	char			name[FCSIM_WWN_BUFLEN];
};

/* TMR response hand-off between SCSI EH and LIO (fcsim_cmd.tmr_state). */
enum fcsim_tmr_state {
	FCSIM_TMR_PENDING,
	FCSIM_TMR_RESPONDED,	/* queue_tm_rsp: EH reads it and drops the ACK ref */
	FCSIM_TMR_ABORTED,	/* aborted_task: LIO drops the ACK ref itself */
	FCSIM_TMR_ABANDONED,	/* EH gave up waiting; queue_tm_rsp drops the ref */
};

/*
 * An exchange: one command (or TMR) on the fabric.  Allocated separately
 * from the scsi_cmnd, like an HBA's own I/O context, so that the initiator
 * side can terminate it (EH, terminate_rport_io, logout) at any time and
 * get the scsi_cmnd back, while LIO may still be working on it.  LIO gets
 * its own data buffers; data is copied to/from the scsi_cmnd only while
 * it is attached (->sc != NULL, under ->lock).
 *
 * References: one for the SCSI side (dropped when ->sc is detached) and one
 * for LIO (taken when handed over, dropped in release_cmd).  The cache is
 * SLAB_TYPESAFE_BY_RCU so that EH can look an exchange up from its
 * scsi_cmnd and re-check ->sc under ->lock.
 */
struct fcsim_cmd {
	spinlock_t		lock;		/* survives TYPESAFE_BY_RCU reuse */
	struct_group(body,
	struct se_cmd		se_cmd;
	struct fcsim_iport	*iport;
	struct scsi_cmnd	*sc;		/* NULL: completed or terminated */
	struct kref		kref;
	bool			lio;		/* handed to LIO */
	bool			held;		/* on iport->held_list */
	bool			drop_rsp;	/* fault: the response gets lost */
	u64			tport_wwpn;
	u64			lun;
	u64			tag;
	u32			data_len;
	u8			dir;		/* enum dma_data_direction */
	u8			tmr_state;	/* enum fcsim_tmr_state (TMR only) */
	u8			cdb[32];
	struct list_head	held_node;
	struct timer_list	delay_timer;
	struct completion	tmr_done;
	unsigned char		sense_buf[TRANSPORT_SENSE_BUFFER];
	);
};

/* scsi_cmd_priv() */
struct fcsim_scmd {
	struct fcsim_cmd	*cmd;		/* attached exchange, if any */
};

/* fcsim_main.c: fabric */
extern struct mutex fcsim_mutex;
extern struct list_head fcsim_iports;
extern struct list_head fcsim_tports;
extern u64 fcsim_fabric_wwn;
extern struct device *fcsim_root_dev;

void fcsim_fabric_kick(void);
void fcsim_fabric_sync(void);
void fcsim_wait_drained(atomic_t *ndraining);
void fcsim_forget_refusals(struct fcsim_iport *iport, struct fcsim_tport *tport);
ssize_t fcsim_emit_name(char *page, ssize_t len, const char *name,
			unsigned int *more);
ssize_t fcsim_emit_more(char *page, ssize_t len, unsigned int more);
int fcsim_port_id_alloc(u32 *port_id);
void fcsim_port_id_free(u32 port_id);
bool fcsim_wwpn_in_use(u64 wwpn);
struct fcsim_nexus *fcsim_nexus_lookup_rcu(struct fcsim_iport *iport, u64 tport_wwpn);

int fcsim_parse_wwn(const char *str, u64 *wwn);
void fcsim_format_wwn(char *buf, size_t len, u64 wwn);
u64 fcsim_default_wwnn(u64 wwpn);

/* fcsim_ini.c: initiator side */
int fcsim_ini_init(void);
void fcsim_ini_exit(void);
struct fcsim_iport *fcsim_iport_create(u64 wwpn);
void fcsim_iport_destroy(struct fcsim_iport *iport);
void fcsim_iport_set_link(struct fcsim_iport *iport, bool up);
int fcsim_iport_set_wwnn(struct fcsim_iport *iport, u64 wwnn);
int fcsim_rport_add(struct fcsim_nexus *nexus);
void fcsim_rport_delete(struct fcsim_nexus *nexus);
void fcsim_post_rscn(struct fcsim_iport *iport, u32 port_id);
void fcsim_terminate_tport(struct fcsim_iport *iport, u64 tport_wwpn);

/* fcsim_ini.c: exchange hooks for the LIO callbacks */
void fcsim_xchg_put(struct fcsim_cmd *cmd);
bool fcsim_xchg_fetch_write_data(struct fcsim_cmd *cmd);
void fcsim_xchg_status(struct fcsim_cmd *cmd, bool data_in);
void fcsim_xchg_aborted(struct fcsim_cmd *cmd);
void fcsim_xchg_released(struct fcsim_cmd *cmd);

/* fcsim_tgt.c: target side (LIO fabric) */
int fcsim_tgt_init(void);
void fcsim_tgt_exit(void);
bool fcsim_tport_online(struct fcsim_tport *tport);
int fcsim_tgt_login(struct fcsim_nexus *nexus);
void fcsim_tgt_logout(struct fcsim_nexus *nexus);

/* fcsim_fault.c: fault injection rules */
extern const struct config_item_type fcsim_faults_type;
bool fcsim_fault_eval(struct fcsim_iport *iport, u64 tport_wwpn, bool tmr,
		      struct fcsim_fault_action *act);

/* fcsim_cfs.c: /sys/kernel/config/fcsim */
int fcsim_cfs_init(void);
void fcsim_cfs_exit(void);

#endif /* _TCM_FCSIM_H */

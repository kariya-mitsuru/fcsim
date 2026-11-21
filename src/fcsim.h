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
};

/* Initiator port: one virtual HBA port = one Scsi_Host. */
struct fcsim_iport {
	struct list_head	node;		/* fcsim_iports */
	struct config_group	group;		/* /sys/kernel/config/fcsim/hosts/<wwpn> */
	struct Scsi_Host	*shost;
	u64			wwpn;
	u64			wwnn;
	u32			port_id;
	bool			link_up;
	bool			removing;
	struct list_head	nexus_list;
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
	struct list_head	nexus_list;
	struct fcsim_tpg_attrib	attrib;
	struct se_portal_group	se_tpg;
	struct se_wwn		se_wwn;
	char			name[FCSIM_WWN_BUFLEN];
};

/* Per-command state; lives in scsi_cmd_priv() for I/O, kzalloc'ed for TMRs. */
struct fcsim_cmd {
	struct se_cmd		se_cmd;
	struct scsi_cmnd	*sc;		/* NULL for TMRs */
	/*
	 * Set (inside an RCU read section that also covers scsi_done()) once
	 * the target side is completely done with this command.  SCSI EH
	 * waits for it before handing a timed-out command back to the
	 * midlayer, which may then reuse it.
	 */
	bool			released;
	struct completion	tmr_done;
	unsigned char		sense_buf[TRANSPORT_SENSE_BUFFER];
};

/* fcsim_main.c: fabric */
extern struct mutex fcsim_mutex;
extern struct list_head fcsim_iports;
extern struct list_head fcsim_tports;
extern u64 fcsim_fabric_wwn;
extern struct device *fcsim_root_dev;

void fcsim_fabric_kick(void);
void fcsim_fabric_sync(void);
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
void fcsim_cmd_done(struct fcsim_cmd *cmd);
void fcsim_rport_delete(struct fcsim_nexus *nexus);

/* fcsim_tgt.c: target side (LIO fabric) */
int fcsim_tgt_init(void);
void fcsim_tgt_exit(void);
bool fcsim_tport_online(struct fcsim_tport *tport);
int fcsim_tgt_login(struct fcsim_nexus *nexus);
void fcsim_tgt_logout(struct fcsim_nexus *nexus);

/* fcsim_cfs.c: /sys/kernel/config/fcsim */
int fcsim_cfs_init(void);
void fcsim_cfs_exit(void);

#endif /* _TCM_FCSIM_H */

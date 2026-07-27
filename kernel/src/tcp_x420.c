// SPDX-License-Identifier: GPL-2.0
/*
 * X420 TCP congestion control prototype
 *
 * A delivery-rate controller for long-lived encrypted proxy connections.
 * X420 keeps a BDP model, reacts to persistent queue growth before loss, and
 * uses loss as a secondary signal.  It is intentionally a research prototype,
 * not a claim of production safety or general Internet fairness.
 */

#include <linux/jiffies.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/string.h>
#include <linux/types.h>
#include <net/tcp.h>

#define X420_BW_SCALE		24
#define X420_BW_UNIT		(1U << X420_BW_SCALE)
#define X420_MARK_MAGIC		0x04200000U
#define X420_MARK_MASK		0xffff0000U
#define X420_CLASS_MASK		0x000000ffU

enum x420_mode {
	X420_STARTUP,
	X420_DRAIN,
	X420_CRUISE,
};

struct x420 {
	u64	bw;
	u64	full_bw;
	u32	min_rtt_us;
	u32	min_rtt_stamp;
	u32	next_rtt_delivered;
	u32	rtt_cnt;
	u32	prior_cwnd;
	u8	mode;
	u8	full_bw_cnt;
	u8	round_start;
	u8	idle_restart;
};

static unsigned int queue_target_pct = 12;
module_param(queue_target_pct, uint, 0644);
MODULE_PARM_DESC(queue_target_pct,
		 "Target queue delay as a percentage of minimum RTT");

static unsigned int queue_target_min_us = 2000;
module_param(queue_target_min_us, uint, 0644);
MODULE_PARM_DESC(queue_target_min_us, "Minimum queue-delay target in usec");

static unsigned int queue_target_max_us = 20000;
module_param(queue_target_max_us, uint, 0644);
MODULE_PARM_DESC(queue_target_max_us, "Maximum queue-delay target in usec");

static unsigned int cwnd_gain_pct = 150;
module_param(cwnd_gain_pct, uint, 0644);
MODULE_PARM_DESC(cwnd_gain_pct, "Steady-state cwnd gain in percent of BDP");

static unsigned int probe_gain_pct = 110;
module_param(probe_gain_pct, uint, 0644);
MODULE_PARM_DESC(probe_gain_pct, "Bandwidth-probe pacing gain in percent");

static unsigned int loss_beta = 875;
module_param(loss_beta, uint, 0644);
MODULE_PARM_DESC(loss_beta, "Loss response in thousandths of current cwnd");

static u8 x420_flow_class(const struct sock *sk)
{
	u32 mark = READ_ONCE(sk->sk_mark);

	if ((mark & X420_MARK_MASK) != X420_MARK_MAGIC)
		return 0;
	return mark & X420_CLASS_MASK;
}

static u32 x420_queue_target(const struct x420 *ca)
{
	u64 target;
	u32 lower, upper;

	target = (u64)ca->min_rtt_us *
		 clamp_t(unsigned int, queue_target_pct, 1, 50);
	do_div(target, 100);
	lower = max_t(unsigned int, queue_target_min_us, 250);
	upper = max_t(unsigned int, queue_target_max_us, lower);
	return clamp_t(u32, target, lower, upper);
}

static void x420_update_round(struct sock *sk,
			      const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct x420 *ca = inet_csk_ca(sk);

	ca->round_start = 0;
	if (!before(rs->prior_delivered, ca->next_rtt_delivered)) {
		ca->next_rtt_delivered = tp->delivered;
		ca->rtt_cnt++;
		ca->round_start = 1;
	}
}

static void x420_update_bw(struct sock *sk, const struct rate_sample *rs)
{
	struct x420 *ca = inet_csk_ca(sk);
	u64 sample;

	if (rs->delivered <= 0 || rs->interval_us <= 0)
		return;

	sample = div64_u64((u64)rs->delivered * X420_BW_UNIT,
			   rs->interval_us);

	if (!rs->is_app_limited || sample > ca->bw) {
		if (sample >= ca->bw) {
			ca->bw = sample;
		} else if (ca->round_start) {
			/* Slow decay follows a persistent path-capacity reduction. */
			ca->bw = max(sample, ca->bw - (ca->bw >> 4));
		}
	}
}

static void x420_update_min_rtt(struct x420 *ca,
				const struct rate_sample *rs)
{
	bool expired;

	if (rs->rtt_us <= 0)
		return;

	expired = time_after32(tcp_jiffies32,
			       ca->min_rtt_stamp + 10 * HZ);
	if (expired || rs->rtt_us < ca->min_rtt_us) {
		ca->min_rtt_us = rs->rtt_us;
		ca->min_rtt_stamp = tcp_jiffies32;
	}
}

static u32 x420_bdp(const struct sock *sk, unsigned int gain_pct)
{
	const struct x420 *ca = inet_csk_ca(sk);
	u64 packets;

	if (!ca->bw || ca->min_rtt_us == ~0U)
		return TCP_INIT_CWND;

	packets = ca->bw * ca->min_rtt_us;
	packets = (packets * gain_pct + 100 * X420_BW_UNIT - 1) /
		  (100 * X420_BW_UNIT);
	return clamp_t(u64, packets, 4, tcp_sk(sk)->snd_cwnd_clamp);
}

static unsigned long x420_pacing_rate(const struct sock *sk,
				      unsigned int gain_pct)
{
	const struct tcp_sock *tp = tcp_sk(sk);
	const struct x420 *ca = inet_csk_ca(sk);
	u64 rate;

	if (!ca->bw)
		return 0;

	rate = ca->bw * max_t(u32, tp->mss_cache, 1);
	rate *= USEC_PER_SEC;
	rate >>= X420_BW_SCALE;
	rate = div64_u64(rate * gain_pct, 100);
	return min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate));
}

static void x420_check_full_pipe(struct x420 *ca)
{
	if (!ca->round_start || ca->mode != X420_STARTUP || !ca->bw)
		return;

	if (!ca->full_bw || ca->bw >= ca->full_bw + ca->full_bw / 8) {
		ca->full_bw = ca->bw;
		ca->full_bw_cnt = 0;
		return;
	}

	if (++ca->full_bw_cnt >= 3)
		ca->mode = X420_DRAIN;
}

static unsigned int x420_pacing_gain(const struct sock *sk,
				     const struct rate_sample *rs)
{
	const struct tcp_sock *tp = tcp_sk(sk);
	const struct x420 *ca = inet_csk_ca(sk);
	u32 current_rtt, queue_delay, target;
	u8 flow_class = x420_flow_class(sk);

	current_rtt = rs->rtt_us > 0 ? rs->rtt_us :
		      max_t(u32, tp->srtt_us >> 3, 1);
	queue_delay = current_rtt > ca->min_rtt_us ?
		      current_rtt - ca->min_rtt_us : 0;
	target = x420_queue_target(ca);

	if (queue_delay > 2 * target)
		return 75;
	if (queue_delay > target)
		return 90;

	if (flow_class == 1 || flow_class == 2)
		return 100;

	switch (ca->mode) {
	case X420_STARTUP:
		return 200;
	case X420_DRAIN:
		return 75;
	case X420_CRUISE:
	default:
		if ((ca->rtt_cnt & 7) == 0)
			return clamp_t(unsigned int, probe_gain_pct, 101, 125);
		if ((ca->rtt_cnt & 7) == 1)
			return 90;
		return 100;
	}
}

static void x420_set_cwnd(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	u32 cwnd = tcp_snd_cwnd(tp);
	u32 gain = clamp_t(unsigned int, cwnd_gain_pct, 100, 250);
	u32 target, acked;
	u8 flow_class = x420_flow_class(sk);

	if (flow_class == 1 || flow_class == 2)
		gain = min(gain, 125U);
	else if (flow_class == 4)
		gain = max(gain, 175U);

	target = x420_bdp(sk, gain);
	acked = max_t(int, rs->acked_sacked, 0);

	if (rs->losses > 0) {
		u32 beta = clamp_t(unsigned int, loss_beta, 500, 950);

		cwnd = max_t(u32, 4, div_u64((u64)cwnd * beta, 1000));
	} else if (cwnd < target) {
		cwnd += min(acked, target - cwnd);
	} else if (cwnd > target + max_t(u32, target >> 3, 2)) {
		/* Drain persistent excess gradually instead of a hard collapse. */
		cwnd--;
	}

	tcp_snd_cwnd_set(tp, clamp_t(u32, cwnd, 4, tp->snd_cwnd_clamp));
}

static void x420_main(struct sock *sk, u32 ack, int flag,
		      const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct x420 *ca = inet_csk_ca(sk);
	unsigned int gain;
	unsigned long rate;

	(void)ack;
	(void)flag;
	x420_update_round(sk, rs);
	x420_update_bw(sk, rs);
	x420_update_min_rtt(ca, rs);
	x420_check_full_pipe(ca);

	if (ca->mode == X420_DRAIN &&
	    tcp_packets_in_flight(tp) <= x420_bdp(sk, 100))
		ca->mode = X420_CRUISE;

	gain = x420_pacing_gain(sk, rs);
	rate = x420_pacing_rate(sk, gain);
	if (rate)
		WRITE_ONCE(sk->sk_pacing_rate, rate);
	x420_set_cwnd(sk, rs);
	ca->idle_restart = 0;
}

static void x420_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct x420 *ca = inet_csk_ca(sk);
	u32 initial_rtt;

	memset(ca, 0, sizeof(*ca));
	initial_rtt = tcp_min_rtt(tp);
	ca->min_rtt_us = initial_rtt ? initial_rtt : ~0U;
	ca->min_rtt_stamp = tcp_jiffies32;
	ca->next_rtt_delivered = tp->delivered;
	ca->mode = X420_STARTUP;
	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;
	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
}

static u32 x420_ssthresh(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct x420 *ca = inet_csk_ca(sk);
	u32 beta = clamp_t(unsigned int, loss_beta, 500, 950);

	ca->prior_cwnd = tcp_snd_cwnd(tp);
	return max_t(u32, 4,
		     div_u64((u64)tcp_snd_cwnd(tp) * beta, 1000));
}

static u32 x420_undo_cwnd(struct sock *sk)
{
	const struct x420 *ca = inet_csk_ca(sk);

	return max(tcp_snd_cwnd(tcp_sk(sk)), ca->prior_cwnd);
}

static void x420_cwnd_event(struct sock *sk, enum tcp_ca_event event)
{
	struct x420 *ca = inet_csk_ca(sk);

	if (event == CA_EVENT_TX_START) {
		ca->idle_restart = 1;
		ca->mode = ca->bw ? X420_CRUISE : X420_STARTUP;
	}
}

static struct tcp_congestion_ops x420_cong_ops __read_mostly = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "x420",
	.owner		= THIS_MODULE,
	.init		= x420_init,
	.cong_control	= x420_main,
	.ssthresh	= x420_ssthresh,
	.undo_cwnd	= x420_undo_cwnd,
	.cwnd_event	= x420_cwnd_event,
};

static int __init x420_register(void)
{
	BUILD_BUG_ON(sizeof(struct x420) > ICSK_CA_PRIV_SIZE);
	return tcp_register_congestion_control(&x420_cong_ops);
}

static void __exit x420_unregister(void)
{
	tcp_unregister_congestion_control(&x420_cong_ops);
}

module_init(x420_register);
module_exit(x420_unregister);

MODULE_AUTHOR("X420 research prototype");
MODULE_DESCRIPTION("Queue-aware delivery-rate TCP congestion control");
MODULE_LICENSE("GPL");

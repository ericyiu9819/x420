#!/usr/bin/env bash
set -euo pipefail

# edge_proxy_splice_only.sh
# Single-file installer/generator for a splice(2)-only TCP relay.
# Target platform: Ubuntu 22.04/24.04 or Debian-like Linux VPS.
#
# Quick start:
#   bash edge_proxy_splice_only.sh quickstart /root/edge-proxy
#
# This script intentionally does not generate io_uring relay or XDP components.

PROJECT_DIR="${2:-./edge-proxy}"

usage() {
  cat <<'EOF'
Usage:
  bash edge_proxy_splice_only.sh quickstart [project_dir]
  bash edge_proxy_splice_only.sh deps
  bash edge_proxy_splice_only.sh bootstrap [project_dir]
  bash edge_proxy_splice_only.sh build [project_dir]
  bash edge_proxy_splice_only.sh bench [project_dir]
  bash edge_proxy_splice_only.sh run [project_dir] -- --listen-port 9100 --target-host 127.0.0.1 --target-port 5201

What quickstart does:
  deps -> bootstrap splice-only project -> build edge-splice-relay -> run splice-only benchmark.

Benchmark behavior:
  - Starts iperf3 target on 127.0.0.1:5201.
  - Starts edge-splice-relay on 127.0.0.1:9100.
  - Runs iperf3 only through the splice relay path.
  - Set DIRECT_BASELINE=1 if you also want a direct iperf3 reference before the splice test.

Scope:
  - Pure TCP transparent relay fast path.
  - Not a VLESS/REALITY/Shadowrocket-compatible proxy by itself.
EOF
}

need_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script targets Linux. Current OS: $(uname -s)" >&2
    exit 1
  fi
}

install_deps() {
  need_linux
  if command -v apt-get >/dev/null 2>&1; then
    local sudo_cmd=""
    if [[ "${EUID}" -ne 0 ]]; then sudo_cmd="sudo"; fi
    $sudo_cmd apt-get update
    $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config make gcc iproute2 iperf3
  else
    echo "apt-get not found. Install manually: gcc make pkg-config iproute2 iperf3" >&2
    exit 1
  fi
}

bootstrap_project() {
  local dir="${1:-$PROJECT_DIR}"
  mkdir -p "$dir"/{src,bench,build}

  cat > "$dir/README.md" <<'EOF'
# edge-proxy splice-only

This is a C + splice(2) TCP relay. It uses Linux `splice(socket -> pipe -> socket)`
to reduce user-space copying on pure TCP forwarding paths.

Implemented:

- `edge-splice-relay`
- splice-only local iperf3 benchmark

Not included:

- io_uring relay
- XDP/eBPF
- VLESS/REALITY/TLS
- Shadowrocket-compatible proxy protocol

## Build

```bash
make
```

## Benchmark

```bash
./bench/local_iperf_splice.sh
```

## Run

```bash
./build/edge-splice-relay \
  --listen-host 0.0.0.0 \
  --listen-port 9100 \
  --target-host 127.0.0.1 \
  --target-port 5201 \
  --workers 1 \
  --chunk 4194304
```
EOF

  cat > "$dir/Makefile" <<'EOF'
CC ?= gcc
CFLAGS ?= -O3 -g -std=gnu11 -Wall -Wextra -Wshadow -Wno-unused-parameter -D_GNU_SOURCE
BUILD_DIR := build
SPLICE_RELAY := $(BUILD_DIR)/edge-splice-relay

.PHONY: all clean splice

all: splice

splice: $(SPLICE_RELAY)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(SPLICE_RELAY): src/splice_relay.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -rf $(BUILD_DIR)
EOF

  cat > "$dir/src/splice_relay.c" <<'EOF'
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SO_REUSEPORT
#define SO_REUSEPORT 15
#endif

#define DEFAULT_LISTEN_HOST "0.0.0.0"
#define DEFAULT_LISTEN_PORT "9100"
#define DEFAULT_TARGET_HOST "127.0.0.1"
#define DEFAULT_TARGET_PORT "5201"
#define DEFAULT_BACKLOG 4096
#define DEFAULT_CHUNK 4194304UL
#define DEFAULT_MAX_EVENTS 4096

enum fd_kind {
    FD_LISTENER = 1,
    FD_CLIENT = 2,
    FD_UPSTREAM = 3
};

enum dir_id {
    C2U = 0,
    U2C = 1
};

struct config {
    const char *listen_host;
    const char *listen_port;
    const char *target_host;
    const char *target_port;
    int backlog;
    unsigned workers;
    size_t chunk;
    int verbose;
};

struct relay_state;

struct direction {
    int src_fd;
    int dst_fd;
    int pipe_rd;
    int pipe_wr;
    size_t in_pipe;
    int src_eof;
};

struct conn {
    struct relay_state *st;
    int client_fd;
    int upstream_fd;
    int connecting;
    int closed;
    struct direction dir[2];
};

struct fd_ctx {
    enum fd_kind kind;
    struct conn *conn;
};

struct relay_state {
    int epfd;
    int listen_fd;
    struct sockaddr_storage target_addr;
    socklen_t target_len;
    struct config cfg;
    struct fd_ctx listen_ctx;
    uint64_t accepted;
    uint64_t closed;
    uint64_t bytes_c2u;
    uint64_t bytes_u2c;
};

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static unsigned parse_uint(const char *s, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long v = strtoul(s, &end, 10);
    if (errno || !end || *end != '\0' || v == 0 || v > 100000000UL) {
        fprintf(stderr, "invalid %s: %s\n", name, s);
        exit(2);
    }
    return (unsigned)v;
}

static size_t parse_size(const char *s, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno || !end || *end != '\0' || v == 0 || v > (1ULL << 31)) {
        fprintf(stderr, "invalid %s: %s\n", name, s);
        exit(2);
    }
    return (size_t)v;
}

static void set_tcp_opts(int fd) {
    int one = 1;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
}

static int make_pipe(int p[2], size_t pipe_sz) {
    if (pipe2(p, O_NONBLOCK | O_CLOEXEC) < 0) return -1;
#ifdef F_SETPIPE_SZ
    (void)fcntl(p[0], F_SETPIPE_SZ, (int)pipe_sz);
    (void)fcntl(p[1], F_SETPIPE_SZ, (int)pipe_sz);
#endif
    return 0;
}

static int resolve_target(struct relay_state *st) {
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int rc = getaddrinfo(st->cfg.target_host, st->cfg.target_port, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "getaddrinfo target %s:%s: %s\n",
                st->cfg.target_host, st->cfg.target_port, gai_strerror(rc));
        return -1;
    }
    memcpy(&st->target_addr, res->ai_addr, res->ai_addrlen);
    st->target_len = (socklen_t)res->ai_addrlen;
    freeaddrinfo(res);
    return 0;
}

static int create_listener(const struct config *cfg) {
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *rp = NULL;
    int fd = -1;
    int one = 1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    int rc = getaddrinfo(cfg->listen_host, cfg->listen_port, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "getaddrinfo listen %s:%s: %s\n",
                cfg->listen_host, cfg->listen_port, gai_strerror(rc));
        return -1;
    }

    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype | SOCK_NONBLOCK, rp->ai_protocol);
        if (fd < 0) continue;
        (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        (void)setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
        if (bind(fd, rp->ai_addr, rp->ai_addrlen) == 0 && listen(fd, cfg->backlog) == 0) break;
        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    return fd;
}

static void close_conn(struct conn *c) {
    if (!c || c->closed) return;
    c->closed = 1;
    if (c->client_fd >= 0) close(c->client_fd);
    if (c->upstream_fd >= 0) close(c->upstream_fd);
    for (int i = 0; i < 2; i++) {
        if (c->dir[i].pipe_rd >= 0) close(c->dir[i].pipe_rd);
        if (c->dir[i].pipe_wr >= 0) close(c->dir[i].pipe_wr);
    }
    c->st->closed++;
}

static int ep_mod_fd(struct relay_state *st, int fd, struct fd_ctx *ctx, uint32_t events) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events | EPOLLERR | EPOLLHUP | EPOLLRDHUP;
    ev.data.ptr = ctx;
    if (epoll_ctl(st->epfd, EPOLL_CTL_MOD, fd, &ev) == 0) return 0;
    if (errno == ENOENT) return epoll_ctl(st->epfd, EPOLL_CTL_ADD, fd, &ev);
    return -1;
}

static void update_events(struct conn *c) {
    if (!c || c->closed) return;

    struct relay_state *st = c->st;
    struct fd_ctx *client_ctx = NULL;
    struct fd_ctx *upstream_ctx = NULL;

    client_ctx = (struct fd_ctx *)(c + 1);
    upstream_ctx = client_ctx + 1;

    if (c->connecting) {
        (void)ep_mod_fd(st, c->upstream_fd, upstream_ctx, EPOLLOUT);
        return;
    }

    uint32_t ce = 0;
    uint32_t ue = 0;

    if (!c->dir[C2U].src_eof && c->dir[C2U].in_pipe < st->cfg.chunk) ce |= EPOLLIN;
    if (c->dir[U2C].in_pipe > 0) ce |= EPOLLOUT;

    if (!c->dir[U2C].src_eof && c->dir[U2C].in_pipe < st->cfg.chunk) ue |= EPOLLIN;
    if (c->dir[C2U].in_pipe > 0) ue |= EPOLLOUT;

    (void)ep_mod_fd(st, c->client_fd, client_ctx, ce);
    (void)ep_mod_fd(st, c->upstream_fd, upstream_ctx, ue);
}

static int pump_one(struct conn *c, enum dir_id id) {
    struct direction *d = &c->dir[id];
    struct relay_state *st = c->st;
    const unsigned splice_flags = SPLICE_F_MOVE | SPLICE_F_NONBLOCK;

    for (;;) {
        int progressed = 0;

        while (!d->src_eof && d->in_pipe < st->cfg.chunk) {
            size_t want = st->cfg.chunk - d->in_pipe;
            ssize_t n = splice(d->src_fd, NULL, d->pipe_wr, NULL, want, splice_flags);
            if (n > 0) {
                d->in_pipe += (size_t)n;
                progressed = 1;
                continue;
            }
            if (n == 0) {
                d->src_eof = 1;
                progressed = 1;
                break;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return -1;
        }

        while (d->in_pipe > 0) {
            ssize_t n = splice(d->pipe_rd, NULL, d->dst_fd, NULL, d->in_pipe, splice_flags);
            if (n > 0) {
                d->in_pipe -= (size_t)n;
                if (id == C2U) st->bytes_c2u += (uint64_t)n;
                else st->bytes_u2c += (uint64_t)n;
                progressed = 1;
                continue;
            }
            if (n == 0) break;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return -1;
        }

        if (d->src_eof && d->in_pipe == 0) {
            shutdown(d->dst_fd, SHUT_WR);
            return 0;
        }

        if (!progressed) return 0;
    }
}

static struct conn *new_conn(struct relay_state *st, int client_fd) {
    int upstream_fd = socket(st->target_addr.ss_family, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (upstream_fd < 0) return NULL;
    set_tcp_opts(client_fd);
    set_tcp_opts(upstream_fd);

    size_t alloc_sz = sizeof(struct conn) + 2 * sizeof(struct fd_ctx);
    struct conn *c = calloc(1, alloc_sz);
    if (!c) {
        close(upstream_fd);
        return NULL;
    }

    c->st = st;
    c->client_fd = client_fd;
    c->upstream_fd = upstream_fd;
    for (int i = 0; i < 2; i++) {
        c->dir[i].pipe_rd = -1;
        c->dir[i].pipe_wr = -1;
    }

    int p1[2], p2[2];
    p1[0] = p1[1] = p2[0] = p2[1] = -1;
    if (make_pipe(p1, st->cfg.chunk) < 0 || make_pipe(p2, st->cfg.chunk) < 0) {
        if (p1[0] >= 0) close(p1[0]);
        if (p1[1] >= 0) close(p1[1]);
        if (p2[0] >= 0) close(p2[0]);
        if (p2[1] >= 0) close(p2[1]);
        close(upstream_fd);
        free(c);
        return NULL;
    }

    c->dir[C2U].src_fd = client_fd;
    c->dir[C2U].dst_fd = upstream_fd;
    c->dir[C2U].pipe_rd = p1[0];
    c->dir[C2U].pipe_wr = p1[1];

    c->dir[U2C].src_fd = upstream_fd;
    c->dir[U2C].dst_fd = client_fd;
    c->dir[U2C].pipe_rd = p2[0];
    c->dir[U2C].pipe_wr = p2[1];

    struct fd_ctx *client_ctx = (struct fd_ctx *)(c + 1);
    struct fd_ctx *upstream_ctx = client_ctx + 1;
    client_ctx->kind = FD_CLIENT;
    client_ctx->conn = c;
    upstream_ctx->kind = FD_UPSTREAM;
    upstream_ctx->conn = c;

    int rc = connect(upstream_fd, (struct sockaddr *)&st->target_addr, st->target_len);
    if (rc == 0) {
        c->connecting = 0;
    } else if (errno == EINPROGRESS) {
        c->connecting = 1;
    } else {
        close_conn(c);
        return NULL;
    }

    st->accepted++;
    update_events(c);
    return c;
}

static void accept_loop(struct relay_state *st) {
    for (;;) {
        int cfd = accept4(st->listen_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            return;
        }
        if (!new_conn(st, cfd)) close(cfd);
    }
}

static void finish_connect(struct conn *c) {
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(c->upstream_fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0 || err != 0) {
        close_conn(c);
        return;
    }
    c->connecting = 0;
    update_events(c);
}

static void handle_conn_event(struct fd_ctx *ctx, uint32_t events) {
    struct conn *c = ctx->conn;
    if (!c || c->closed) return;

    if (c->connecting) {
        if (ctx->kind == FD_UPSTREAM && (events & EPOLLOUT)) finish_connect(c);
        if (events & (EPOLLERR | EPOLLHUP)) close_conn(c);
        return;
    }

    if (events & EPOLLIN) {
        enum dir_id id = ctx->kind == FD_CLIENT ? C2U : U2C;
        if (pump_one(c, id) < 0) {
            close_conn(c);
            return;
        }
    }

    if (events & EPOLLOUT) {
        enum dir_id id = ctx->kind == FD_CLIENT ? U2C : C2U;
        if (pump_one(c, id) < 0) {
            close_conn(c);
            return;
        }
    }

    if (events & (EPOLLERR | EPOLLHUP)) {
        close_conn(c);
        return;
    }

    if (events & EPOLLRDHUP) {
        enum dir_id id = ctx->kind == FD_CLIENT ? C2U : U2C;
        c->dir[id].src_eof = 1;
        if (c->dir[id].in_pipe == 0) shutdown(c->dir[id].dst_fd, SHUT_WR);
    }

    update_events(c);
}

static int worker_run(const struct config *cfg) {
    struct relay_state st;
    memset(&st, 0, sizeof(st));
    st.cfg = *cfg;
    st.listen_fd = -1;
    st.epfd = -1;

    if (resolve_target(&st) < 0) return 1;
    st.listen_fd = create_listener(cfg);
    if (st.listen_fd < 0) {
        fprintf(stderr, "failed to listen on %s:%s\n", cfg->listen_host, cfg->listen_port);
        return 1;
    }

    st.epfd = epoll_create1(EPOLL_CLOEXEC);
    if (st.epfd < 0) {
        perror("epoll_create1");
        close(st.listen_fd);
        return 1;
    }

    st.listen_ctx.kind = FD_LISTENER;
    st.listen_ctx.conn = NULL;
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN | EPOLLERR | EPOLLHUP;
    ev.data.ptr = &st.listen_ctx;
    if (epoll_ctl(st.epfd, EPOLL_CTL_ADD, st.listen_fd, &ev) < 0) {
        perror("epoll_ctl listen");
        close(st.listen_fd);
        close(st.epfd);
        return 1;
    }

    if (cfg->verbose) {
        fprintf(stderr,
                "edge-splice-relay pid=%ld listen=%s:%s target=%s:%s chunk=%zu\n",
                (long)getpid(), cfg->listen_host, cfg->listen_port,
                cfg->target_host, cfg->target_port, cfg->chunk);
    }

    struct epoll_event *events = calloc(DEFAULT_MAX_EVENTS, sizeof(*events));
    if (!events) {
        perror("calloc events");
        close(st.listen_fd);
        close(st.epfd);
        return 1;
    }

    while (!g_stop) {
        int n = epoll_wait(st.epfd, events, DEFAULT_MAX_EVENTS, 1000);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            break;
        }
        for (int i = 0; i < n; i++) {
            struct fd_ctx *ctx = events[i].data.ptr;
            if (!ctx) continue;
            if (ctx->kind == FD_LISTENER) accept_loop(&st);
            else handle_conn_event(ctx, events[i].events);
        }
    }

    if (cfg->verbose) {
        fprintf(stderr,
                "edge-splice-relay pid=%ld exit accepted=%llu closed=%llu c2u=%llu u2c=%llu\n",
                (long)getpid(),
                (unsigned long long)st.accepted,
                (unsigned long long)st.closed,
                (unsigned long long)st.bytes_c2u,
                (unsigned long long)st.bytes_u2c);
    }

    free(events);
    close(st.listen_fd);
    close(st.epfd);
    return 0;
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  --listen-host HOST    default " DEFAULT_LISTEN_HOST "\n"
            "  --listen-port PORT    default " DEFAULT_LISTEN_PORT "\n"
            "  --target-host HOST    default " DEFAULT_TARGET_HOST "\n"
            "  --target-port PORT    default " DEFAULT_TARGET_PORT "\n"
            "  --workers N           default 1\n"
            "  --chunk BYTES         default %lu\n"
            "  --backlog N           default %d\n"
            "  --verbose\n",
            prog, (unsigned long)DEFAULT_CHUNK, DEFAULT_BACKLOG);
}

static void terminate_children(pid_t *pids, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        if (pids[i] > 0) kill(pids[i], SIGTERM);
    }
}

int main(int argc, char **argv) {
    struct config cfg = {
        .listen_host = DEFAULT_LISTEN_HOST,
        .listen_port = DEFAULT_LISTEN_PORT,
        .target_host = DEFAULT_TARGET_HOST,
        .target_port = DEFAULT_TARGET_PORT,
        .backlog = DEFAULT_BACKLOG,
        .workers = 1,
        .chunk = DEFAULT_CHUNK,
        .verbose = 0,
    };

    enum {
        OPT_LISTEN_HOST = 1000,
        OPT_LISTEN_PORT,
        OPT_TARGET_HOST,
        OPT_TARGET_PORT,
        OPT_WORKERS,
        OPT_CHUNK,
        OPT_BACKLOG,
        OPT_VERBOSE,
        OPT_HELP
    };

    static const struct option opts[] = {
        {"listen-host", required_argument, NULL, OPT_LISTEN_HOST},
        {"listen-port", required_argument, NULL, OPT_LISTEN_PORT},
        {"target-host", required_argument, NULL, OPT_TARGET_HOST},
        {"target-port", required_argument, NULL, OPT_TARGET_PORT},
        {"workers", required_argument, NULL, OPT_WORKERS},
        {"chunk", required_argument, NULL, OPT_CHUNK},
        {"backlog", required_argument, NULL, OPT_BACKLOG},
        {"verbose", no_argument, NULL, OPT_VERBOSE},
        {"help", no_argument, NULL, OPT_HELP},
        {0, 0, 0, 0}
    };

    for (;;) {
        int c = getopt_long(argc, argv, "", opts, NULL);
        if (c == -1) break;
        switch (c) {
        case OPT_LISTEN_HOST: cfg.listen_host = optarg; break;
        case OPT_LISTEN_PORT: cfg.listen_port = optarg; break;
        case OPT_TARGET_HOST: cfg.target_host = optarg; break;
        case OPT_TARGET_PORT: cfg.target_port = optarg; break;
        case OPT_WORKERS: cfg.workers = parse_uint(optarg, "workers"); break;
        case OPT_CHUNK: cfg.chunk = parse_size(optarg, "chunk"); break;
        case OPT_BACKLOG: cfg.backlog = (int)parse_uint(optarg, "backlog"); break;
        case OPT_VERBOSE: cfg.verbose = 1; break;
        case OPT_HELP: usage(argv[0]); return 0;
        default: usage(argv[0]); return 2;
        }
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (cfg.workers == 1) return worker_run(&cfg);

    pid_t *pids = calloc(cfg.workers, sizeof(*pids));
    if (!pids) {
        perror("calloc pids");
        return 1;
    }
    for (unsigned i = 0; i < cfg.workers; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            terminate_children(pids, i);
            free(pids);
            return 1;
        }
        if (pid == 0) {
            if (cfg.verbose) fprintf(stderr, "worker %u pid=%ld starting\n", i, (long)getpid());
            return worker_run(&cfg);
        }
        pids[i] = pid;
    }

    int status = 0;
    (void)wait(&status);
    terminate_children(pids, cfg.workers);
    free(pids);

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
EOF

  cat > "$dir/bench/local_iperf_splice.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLICE_RELAY="$ROOT/build/edge-splice-relay"

TARGET_PORT="${TARGET_PORT:-5201}"
SPLICE_PORT="${SPLICE_PORT:-9100}"
DURATION="${DURATION:-8}"
PARALLEL="${PARALLEL:-4}"
WORKERS="${WORKERS:-1}"
CHUNK="${CHUNK:-4194304}"
DIRECT_BASELINE="${DIRECT_BASELINE:-0}"

if [[ ! -x "$SPLICE_RELAY" ]]; then
  echo "Missing $SPLICE_RELAY. Run: make" >&2
  exit 1
fi
if ! command -v iperf3 >/dev/null 2>&1; then
  echo "iperf3 not found. Install it first." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  for pid in "${SERVER_PID:-}" "${SPLICE_PID:-}"; do
    if [[ -n "$pid" ]]; then kill "$pid" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

iperf3 -s -p "$TARGET_PORT" >"$TMP_DIR/iperf3-server.log" 2>&1 &
SERVER_PID=$!
sleep 0.5

if [[ "$DIRECT_BASELINE" == "1" ]]; then
  echo "== Optional direct baseline: 127.0.0.1:$TARGET_PORT =="
  iperf3 -c 127.0.0.1 -p "$TARGET_PORT" -t "$DURATION" -P "$PARALLEL"
  echo
fi

"$SPLICE_RELAY" \
  --listen-host 127.0.0.1 \
  --listen-port "$SPLICE_PORT" \
  --target-host 127.0.0.1 \
  --target-port "$TARGET_PORT" \
  --workers "$WORKERS" \
  --chunk "$CHUNK" \
  --verbose >"$TMP_DIR/splice.log" 2>&1 &
SPLICE_PID=$!
sleep 0.8

echo "== splice relay: 127.0.0.1:$SPLICE_PORT -> 127.0.0.1:$TARGET_PORT =="
iperf3 -c 127.0.0.1 -p "$SPLICE_PORT" -t "$DURATION" -P "$PARALLEL"

echo
echo "splice relay log:"
tail -20 "$TMP_DIR/splice.log" || true
EOF
  chmod +x "$dir/bench/local_iperf_splice.sh"

  echo "Generated splice-only project at: $dir"
}

build_project() {
  local dir="${1:-$PROJECT_DIR}"
  if [[ ! -f "$dir/Makefile" || ! -f "$dir/src/splice_relay.c" ]]; then
    bootstrap_project "$dir"
  fi
  (cd "$dir" && make clean && make)
}

bench_project() {
  local dir="${1:-$PROJECT_DIR}"
  build_project "$dir"
  (cd "$dir" && ./bench/local_iperf_splice.sh)
}

run_project() {
  local dir="${1:-$PROJECT_DIR}"
  shift || true
  build_project "$dir" >/dev/null
  if [[ "${1:-}" == "--" ]]; then shift; fi
  (cd "$dir" && exec ./build/edge-splice-relay "$@")
}

cmd="${1:-}"
case "$cmd" in
  deps)
    install_deps
    ;;
  bootstrap)
    bootstrap_project "${2:-./edge-proxy}"
    ;;
  build)
    build_project "${2:-./edge-proxy}"
    ;;
  bench)
    bench_project "${2:-./edge-proxy}"
    ;;
  run)
    run_project "${2:-./edge-proxy}" "${@:3}"
    ;;
  quickstart)
    dir="${2:-./edge-proxy}"
    install_deps
    bootstrap_project "$dir"
    build_project "$dir"
    bench_project "$dir"
    ;;
  ""|help|--help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac

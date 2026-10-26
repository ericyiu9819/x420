#!/usr/bin/env bash
# v2: per-VPS automatic REALITY target selection, deployment and diagnostics.
set -euo pipefail
umask 077
if ! command -v python3 >/dev/null 2>&1; then
  case "${1:-help}" in
    install)
      if [[ $(id -u) != 0 ]] || ! command -v apt-get >/dev/null 2>&1; then
        echo '需要 Python 3；服务端支持 Debian/Ubuntu，请先安装 python3。' >&2; exit 1
      fi
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3 ca-certificates curl
      ;;
    *) echo '请先安装 Python 3。' >&2; exit 1 ;;
  esac
fi
exec python3 - "$@" <<'PY'
import argparse, concurrent.futures, contextlib, datetime, fcntl, hashlib
import ipaddress, json, os, platform, re, secrets, shutil, socket, ssl
import subprocess, sys, tempfile, time, urllib.parse, uuid, zipfile
from pathlib import Path

VERSION = 'v26.10.21'
SHADOWROCKET_VERSION = 'v26.6.27'
ETC = Path('/etc/vps-proxy')
STATE = Path('/var/lib/vps-proxy')
BIN = Path('/opt/vps-proxy/xray')
UNIT = Path('/etc/systemd/system/vps-proxy.service')
TUNE = Path('/etc/sysctl.d/90-vps-proxy.conf')
SERVICE = 'vps-proxy.service'
USER = 'vps-proxy'
TEST_URL = 'https://speed.cloudflare.com/__down?bytes=33554432'
PRIVATE_NETS = ['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8',
                '169.254.0.0/16','172.16.0.0/12','192.168.0.0/16',
                '224.0.0.0/4','240.0.0.0/4','::/128','::1/128',
                'fc00::/7','fe80::/10','ff00::/8']

def fail(s):
    raise RuntimeError(s)

def run(argv, *, check=True, timeout=90, input=None):
    r = subprocess.run([str(x) for x in argv], input=input, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and r.returncode:
        # Avoid including command arguments: some commands carry keys.
        fail(f'{Path(str(argv[0])).name} 执行失败：{r.stderr[-1500:]}')
    return r

def write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = data if isinstance(data, bytes) else data.encode()
    fd, name = tempfile.mkstemp(prefix='.new-', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)

def dump(obj):
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'

def root_linux():
    if platform.system() != 'Linux' or os.geteuid() != 0:
        fail('此命令必须在 Linux VPS 上使用 sudo/root 执行。')
    if not Path('/run/systemd/system').exists():
        fail('需要正在运行的 systemd；不支持普通 Docker 容器/OpenRC。')

@contextlib.contextmanager
def lock():
    root_linux()
    with open('/run/lock/vps-proxy.lock', 'w') as f:
        try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: fail('另一个部署或优化进程正在运行。')
        yield

def deps():
    info = Path('/etc/os-release').read_text()
    if not re.search(r'^ID=(?:"?)(debian|ubuntu)(?:"?)$', info, re.M):
        fail('服务端脚本支持 Debian/Ubuntu（建议 Debian 12/13、Ubuntu 22.04/24.04）。')
    required = ['curl','openssl','sysctl','ss','useradd','modprobe']
    if any(not shutil.which(c) for c in required) or not Path('/etc/ssl/certs/ca-certificates.crt').exists():
        print('安装系统依赖……', flush=True)
        run(['apt-get','update'], timeout=600)
        env = os.environ.copy(); env['DEBIAN_FRONTEND'] = 'noninteractive'
        subprocess.run(['apt-get','install','-y','curl','ca-certificates','openssl',
                        'iproute2','procps','passwd','kmod'], env=env, check=True)

def curl(url, path=None):
    args = ['curl','--fail','--silent','--show-error','--location','--proto','=https',
            '--proto-redir','=https','--connect-timeout','15','--max-time','180','--retry','2']
    if path: args += ['--output',str(path)]
    return run(args + [url], timeout=600).stdout

def valid_host(s):
    if not s or len(s) > 253 or any(c in s for c in '/@?#[]\r\n\t '):
        fail('服务器地址必须是裸 IP 或域名，不含协议、端口或路径。')
    try:
        ipaddress.ip_address(s); return s
    except ValueError: pass
    if not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', s):
        fail('域名格式不合法。')
    return s

def valid_sni(s):
    valid_host(s)
    try: ipaddress.ip_address(s)
    except ValueError:
        if '.' in s: return s
    fail('--sni 必须是目标站的域名。')

def detect_server():
    for url in ['https://api.ipify.org','https://ipv4.icanhazip.com']:
        try:
            val = curl(url).strip()
            ip = ipaddress.ip_address(val)
            if ip.version == 4 and ip.is_global: return val
        except (RuntimeError, ValueError): pass
    fail('无法自动识别公网 IPv4；请使用 --server 显式指定公网 IP/域名。')

# A seed list, not a claim that any domain is suitable or reachable everywhere.
TARGET_CANDIDATES = [
    'www.amazon.com', 'www.amazon.co.jp', 'aws.amazon.com',
    'www.oracle.com', 'www.ibm.com', 'www.intel.com', 'www.amd.com',
    'www.nvidia.com', 'www.samsung.com', 'www.sony.com', 'www.dell.com',
    'www.lenovo.com', 'www.hp.com', 'www.asus.com', 'www.adobe.com',
    'www.salesforce.com', 'www.cisco.com', 'www.ubuntu.com',
]
# A deliberately incomplete hint list. Unknown ASN does NOT mean no CDN.
SHARED_EDGE_ASNS = {13335, 209242, 54113, 20940, 16625}


def resolve_ips(host, timeout=4):
    try:
        return [str(ipaddress.ip_address(host))]
    except ValueError:
        pass
    code = ('import socket,json,sys; '
            'print(json.dumps(list(dict.fromkeys(x[4][0] for x in '
            'socket.getaddrinfo(sys.argv[1],443,type=socket.SOCK_STREAM)))))')
    try:
        result = run([sys.executable, '-c', code, host], timeout=timeout)
        return list(dict.fromkeys(str(ipaddress.ip_address(x)) for x in json.loads(result.stdout)))
    except subprocess.TimeoutExpired:
        fail(f'DNS 查询超时：{host}')


def local_addresses(server):
    addresses = set(resolve_ips(server))
    if platform.system() == 'Linux' and shutil.which('ip'):
        try:
            info = json.loads(run(['ip', '-j', 'address', 'show'], timeout=4).stdout)
            for interface in info:
                for address in interface.get('addr_info', []):
                    if address.get('local'):
                        addresses.add(str(ipaddress.ip_address(address['local'])))
        except (RuntimeError, ValueError, subprocess.TimeoutExpired):
            pass
    return addresses


def public_target_ip(value):
    ip = ipaddress.ip_address(value)
    # Reject synthetic benchmarking/Fake-IP ranges and mapped private IPv4 too.
    if ip.version == 6 and ip.ipv4_mapped:
        return public_target_ip(str(ip.ipv4_mapped))
    return ip.is_global and not ip.is_multicast and not ip.is_unspecified


def tls_sample(host, address, timeout=3):
    ctx = ssl.create_default_context()
    if not ssl.HAS_TLSv1_3:
        fail('Python/OpenSSL 不支持 TLS 1.3，请更新运行时。')
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_alpn_protocols(['h2'])
    start = time.monotonic()
    with socket.create_connection((address, 443), timeout=timeout) as sock:
        connected = time.monotonic()
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            if tls.version() != 'TLSv1.3' or tls.selected_alpn_protocol() != 'h2':
                fail('TLS 1.3/h2 协商未通过')
            return {'tcp_ms': round((connected-start)*1000, 2),
                    'total_ms': round((time.monotonic()-start)*1000, 2),
                    'tls': tls.version(), 'alpn': tls.selected_alpn_protocol()}


def probe_candidate(host, local, pinned_ip=None):
    row = {'domain': host, 'ok': False, 'addresses': [], 'rejected': []}
    try:
        addresses = [str(ipaddress.ip_address(pinned_ip))] if pinned_ip else resolve_ips(host)
        row['addresses'] = addresses
        safe = []
        for address in addresses:
            normalized = str(ipaddress.ip_address(address).ipv4_mapped or address) if ':' in address else address
            normalized_local = {str(ipaddress.ip_address(x).ipv4_mapped or x) if ':' in x else x for x in local}
            if normalized in normalized_local or not public_target_ip(address):
                row['rejected'].append({'ip': address, 'reason': '本机、非公网或 Fake-IP 地址'})
            else:
                safe.append(address)
        # At most one address from each family: keep scans small and bounded.
        choices = []
        for family in [4, 6]:
            choice = next((x for x in safe if ipaddress.ip_address(x).version == family), None)
            if choice: choices.append(choice)
        if not choices:
            fail('没有安全的公网目标地址（检查 DNS 是否返回 Fake-IP）')
        passed = []
        for address in choices:
            try:
                samples = [tls_sample(host, address) for _ in range(2)]
                totals = [x['total_ms'] for x in samples]
                median = sum(totals)/2
                jitter = max(totals)-min(totals)
                passed.append({'ip': address, 'samples': samples,
                    'median_ms': round(median, 2), 'jitter_ms': round(jitter, 2),
                    'latency_score': round(median+jitter, 2)})
            except (OSError, RuntimeError, ValueError) as e:
                row['rejected'].append({'ip': address, 'reason': str(e)[:240]})
        if not passed: fail('所有候选地址均未通过两次证书/TLS 1.3/h2 检查')
        # ASN is added later and the final IP may change based on its preference.
        row['passed_addresses'] = passed
        row.update(min(passed, key=lambda x: x['latency_score']))
        row['ok'] = True
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        row['error'] = str(e)[:300]
    return row


def probe_target(host, server, pinned_ip=None):
    row = probe_candidate(valid_sni(host), local_addresses(server), pinned_ip)
    if not row['ok']:
        fail(f"目标站检查失败：{host}：{row.get('error')}；使用 --reselect-target 重新筛选或手动 --sni。")
    print(f"目标站检查通过：{host} → {row['ip']} / TLSv1.3 / h2 / {row['median_ms']:.1f} ms")
    return row


def lookup_asn(address):
    if not public_target_ip(address): return []
    if not shutil.which('curl'): return []
    url = 'https://stat.ripe.net/data/network-info/data.json?' + urllib.parse.urlencode({'resource': address})
    try:
        result = run(['curl', '--fail', '--silent', '--show-error', '--proto', '=https',
                      '--proxy', '', '--noproxy', '*', '--connect-timeout', '3',
                      '--max-time', '6', '--max-filesize', '131072', url], timeout=8)
        data = json.loads(result.stdout)
        if data.get('status') != 'ok': return []
        return sorted(set(int(x) for x in data['data'].get('asns', [])))
    except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired):
        return []


def read_candidates(filename=None):
    if filename:
        path = Path(filename)
        if path.stat().st_size > 32768: fail('候选文件过大（最多 32 KiB）。')
        domains = [line.split('#',1)[0].strip().lower().rstrip('.')
                   for line in path.read_text().splitlines()]
        domains = [valid_sni(x) for x in domains if x]
    else:
        domains = list(TARGET_CANDIDATES)
    domains = list(dict.fromkeys(domains))
    if not 1 <= len(domains) <= 64: fail('候选域名数量必须在 1—64 之间。')
    return domains


def target_warnings(binary, host, probe_ip, private):
    # Use the domain here so core hostname warnings cannot be bypassed by IP pinning.
    s = dict(server='127.0.0.1',listen='127.0.0.1',port=443,sni=host,
             uuid=str(uuid.uuid4()),private_key=private,public_key='',short_id='0123456789abcdef',name='probe')
    server = configs(s)[0]
    with tempfile.TemporaryDirectory(prefix='reality-check-') as directory:
        file = Path(directory)/'config.json'; write(file, dump(server))
        result = run([binary,'run','-test','-config',file], check=False, timeout=8)
    if result.returncode:
        return ['Xray 配置检查拒绝此目标']
    lines = (result.stdout + result.stderr).splitlines()
    warnings = [x for x in lines if '[Warning]' in x and 'REALITY:' in x]
    # Verify the final form too (target IP with original SNI).
    s['target_ip'] = probe_ip
    with tempfile.TemporaryDirectory(prefix='reality-ip-check-') as directory:
        file = Path(directory)/'config.json'; write(file, dump(configs(s)[0]))
        result = run([binary,'run','-test','-config',file], check=False, timeout=8)
    if result.returncode: warnings.append('Xray 配置检查拒绝固定 IP 形式')
    return warnings


def verify_reality_target(binary, row, private, public, fingerprint='chrome'):
    # Local-only temporary listeners. The HTTP token verifies the complete proxy path
    # without making arbitrary websites/CDNs an extra availability dependency.
    import http.server
    import threading
    token = secrets.token_hex(24)
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = token.encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self,*args): pass
    def free_port():
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0))
            return listener.getsockname()[1]
    httpd = http.server.HTTPServer(('127.0.0.1',0),Handler)
    thread = threading.Thread(target=httpd.serve_forever,kwargs={'poll_interval':0.1},daemon=True)
    thread.start()
    processes = []
    try:
        s = dict(server='127.0.0.1',listen='127.0.0.1',port=free_port(),
                 sni=row['domain'],target_ip=row['ip'],uuid=str(uuid.uuid4()),
                 private_key=private,public_key=public,short_id=secrets.token_hex(8),name='local-proof')
        server, client, _, _ = configs(s)
        client['outbounds'][0]['streamSettings']['realitySettings']['fingerprint'] = fingerprint
        # Only the temporary loopback-bound proof server can reach this local token.
        # The deployed server retains its private-network deny rules.
        server.pop('routing',None)
        server['outbounds'][0]['settings'] = {'finalRules':[{
            'action':'allow','network':'tcp','ip':['127.0.0.1/32'],
            'port':str(httpd.server_port)}]}
        socks_port = free_port()
        client['inbounds'][0]['port'] = socks_port
        with tempfile.TemporaryDirectory(prefix='reality-proof-') as directory:
            for label,config in [('server',server),('client',client)]:
                file = Path(directory)/(label+'.json');write(file,dump(config))
                processes.append(subprocess.Popen([str(binary),'run','-config',str(file)],
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
            deadline = time.monotonic()+3
            ready = False
            while time.monotonic() < deadline:
                if any(p.poll() is not None for p in processes): fail('临时 Xray 进程退出')
                try:
                    with socket.create_connection(('127.0.0.1',socks_port),timeout=0.15): pass
                    with socket.create_connection(('127.0.0.1',s['port']),timeout=0.15): pass
                    ready = True;break
                except OSError:
                    time.sleep(0.1)
            if not ready: fail('临时 Xray 监听未就绪')
            result = run(['curl','--fail','--silent','--show-error','--proxy',
                          f'socks5h://127.0.0.1:{socks_port}','--noproxy','',
                          '--connect-timeout','3','--max-time','12',
                          f'http://127.0.0.1:{httpd.server_port}/proof'],timeout=15)
            if not secrets.compare_digest(result.stdout,token): fail('本地端到端校验令牌不匹配')
        return True
    finally:
        for process in processes:
            if process.poll() is None: process.terminate()
        for process in processes:
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill();process.wait(timeout=3)
        httpd.shutdown();httpd.server_close();thread.join(timeout=2)


def ranking_key(row):
    return (0 if row.get('same_asn') else 1,
            1 if row.get('known_shared_edge') else 0,
            row['latency_score'], row.get('domain',''), row['ip'])


def scan_targets(server, filename=None, binary=None, use_asn=True):
    domains = read_candidates(filename)
    local = local_addresses(server)
    # Exclude local interface addresses added by local_addresses from ASN inference.
    source_ips = [x for x in resolve_ips(server) if public_target_ip(x)]
    report = {'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'server': server, 'source_ips': source_ips, 'candidates': [],
              'policy': 'certificate + TLS1.3 + h2 twice; core REALITY warnings excluded; '
                        'same ASN first, known shared edge deprioritized, latency + jitter',
              'asn_lookup': use_asn, 'core_checked': bool(binary), 'selected': None}
    print(f'开始筛选 {len(domains)} 个目标域名（最多 6 并发，仅检测候选 TCP 443）……', flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        pending = {pool.submit(probe_candidate, domain, local): domain for domain in domains}
        for future in concurrent.futures.as_completed(pending):
            row = future.result(); report['candidates'].append(row)
            print(('  兼容：' if row['ok'] else '  排除：') + row['domain'] +
                  (f" / {row['median_ms']:.1f} ms" if row['ok'] else ' / '+row.get('error','失败')), flush=True)
    passed = [row for row in report['candidates'] if row['ok']]
    addresses = set(source_ips)
    for row in passed:
        addresses.update(x['ip'] for x in row['passed_addresses'])
    asns = {}
    if use_asn:
        print('查询 RIPEstat ASN 信息；不可用时标记未知并继续……', flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            pending = {pool.submit(lookup_asn, ip): ip for ip in sorted(addresses)}
            for future in concurrent.futures.as_completed(pending):
                asns[pending[future]] = future.result()
    source_asns = sorted({asn for ip in source_ips for asn in asns.get(ip,[])})
    report['source_asns'] = source_asns
    for row in passed:
        for address in row['passed_addresses']:
            address['asns'] = asns.get(address['ip'],[])
            address['same_asn'] = bool(set(address['asns']) & set(source_asns))
            address['known_shared_edge'] = bool(set(address['asns']) & SHARED_EDGE_ASNS)
        row.update(min(row['passed_addresses'], key=ranking_key))
    if binary and passed:
        private, public = keypair(binary)
        for row in passed:
            try:
                warnings = target_warnings(binary,row['domain'],row['ip'],private)
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                warnings = [str(e)[:300]]
            row['core_warnings'] = warnings
            if warnings:
                row['ok'] = False; row['error'] = 'Xray REALITY 目标提示/检查未通过'
                print('  核心排除：'+row['domain'], flush=True)
    eligible = sorted((row for row in passed if row['ok']), key=ranking_key)
    report['ranking'] = [row['domain'] for row in eligible]
    best = None
    if binary:
        for row in eligible[:3]:
            print('验证真实 REALITY 代理请求：'+row['domain']+'……', flush=True)
            try:
                verify_reality_target(binary,row,private,public)
                row['reality_probe'] = True; best = row; break
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                row['reality_probe'] = False; row['ok'] = False
                row['error'] = '真实 REALITY 校验失败：'+str(e)[:300]
                print('  校验失败，继续下一个候选。', flush=True)
    elif eligible:
        best = eligible[0]
    if best:
        report['selected'] = {k: best[k] for k in ['domain','ip','asns','same_asn',
            'known_shared_edge','median_ms','jitter_ms','latency_score']}
        report['selected']['reality_verified'] = bool(best.get('reality_probe'))
        print(f"已选：{best['domain']} → {best['ip']} / {best['median_ms']:.1f} ms / "
              + ('同 ASN' if best['same_asn'] else '未确认同 ASN'), flush=True)
    else:
        print('未能确认合格目标，不会写入服务器配置或切换运行中的服务。', flush=True)
    report['candidates'].sort(key=lambda row: row['domain'])
    return report


def download_xray(version, directory, asset=None):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', version): fail('版本格式应为 v26.10.21。')
    if asset is None:
        arch = {'x86_64':'64','aarch64':'arm64-v8a','arm64':'arm64-v8a'}.get(platform.machine())
        if not arch: fail('仅支持 amd64/arm64。')
        asset = f'Xray-linux-{arch}.zip'
    base = f'https://github.com/XTLS/Xray-core/releases/download/{version}/{asset}'
    archive = Path(directory) / asset
    curl(base, archive)
    digest = curl(base + '.dgst')
    match = re.search(r'^SHA2?-256\s*=\s*([a-fA-F0-9]{64})\s*$', digest, re.M)
    if not match: fail('官方 .dgst 中未找到 SHA256，拒绝安装。')
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if not secrets.compare_digest(actual, match[1].lower()): fail('Xray SHA256 校验失败。')
    # Extract only the binary, never arbitrary archive paths.
    with zipfile.ZipFile(archive) as z:
        data = z.read('xray')
    binary = Path(directory) / 'xray'
    write(binary, data, 0o755)
    run([binary,'version'])
    return binary

def keypair(binary):
    output = run([binary,'x25519']).stdout
    private = re.search(r'^Private\s*Key:\s*(\S+)', output, re.M | re.I)
    public = re.search(r'^(?:Password(?:\s*\(PublicKey\))?|Public\s*Key):\s*(\S+)', output, re.M | re.I)
    if not private or not public: fail('无法识别 Xray x25519 输出。')
    return private[1], public[1]

def deployment_settings(args, old=None):
    old = old or {}
    requested = getattr(args,'client_profile',None)
    profile = requested or old.get('client_profile','modern')
    if getattr(args,'version',None):
        version = args.version
    elif old and (not requested or requested == old.get('client_profile','modern')):
        version = old['version']
    else:
        version = SHADOWROCKET_VERSION if profile == 'shadowrocket' else VERSION
    if profile == 'shadowrocket' and version != SHADOWROCKET_VERSION:
        fail('Shadowrocket 兼容模式目前只验证 v26.6.27；请移除 --version，或切换 --client-profile modern。')
    return profile, version


def client_compatibility(s):
    profile = s.get('client_profile','modern')
    return {'client_profile':profile,'server_version':s.get('version'),
            'native_shadowrocket_verified':False,
            'note':('兼容模式使用较旧官方核心 v26.6.27；自检覆盖新旧 Xray TLS 指纹，不能替代真实 iPhone 验证。'
                    if profile == 'shadowrocket' else
                    '默认 v26.10.21 的 REALITY 要求 X25519MLKEM768 握手；fp=chrome 在各客户端中的实现并不相同，同核心自检不代表 Shadowrocket 兼容。')}


def make_state(binary, args, old=None):
    profile, version = deployment_settings(args, old)
    private, public = (old['private_key'],old['public_key']) if old else keypair(binary)
    server = valid_host(args.server or (old or {}).get('server') or detect_server())
    target = args.sni or (old or {}).get('sni')
    report = None
    if not target or getattr(args, 'reselect_target', False):
        report = scan_targets(server, getattr(args,'candidates_file',None), binary,
                              not getattr(args,'no_asn',False))
        if not report['selected']:
            STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
            write(STATE/'target-scan-failed.json', dump(report))
            fail('自动筛选失败；详情见 /var/lib/vps-proxy/target-scan-failed.json。可自定义候选文件或 --sni。')
        target = report['selected']['domain']
    sni = valid_sni(target)
    port = args.port if args.port is not None else (old or {}).get('port',443)
    listen = args.listen or (old or {}).get('listen','0.0.0.0')
    if not 1 <= port <= 65535: fail('端口必须在 1—65535 之间。')
    try: ipaddress.ip_address(listen)
    except ValueError: fail('--listen 必须是本机 IP。')
    try:
        if ipaddress.ip_address(server).version == 6 and ipaddress.ip_address(listen).version != 6:
            fail('公网地址是 IPv6；请同时指定 --listen ::。')
    except ValueError: pass
    name = args.name or (old or {}).get('name') or socket.gethostname()
    if name in ['PROXY','DIRECT','REJECT','GLOBAL']:
        fail('节点名称不能使用保留名称 PROXY / DIRECT / REJECT / GLOBAL。')
    state = dict(server=server,sni=sni,port=port,listen=listen,
                name=name,
                uuid=(old or {}).get('uuid') or str(uuid.uuid4()),
                private_key=private,public_key=public,
                short_id=(old or {}).get('short_id') or secrets.token_hex(8),
                version=version,client_profile=profile)
    if report:
        state['target_ip'] = report['selected']['ip']
        state['target_selection'] = report['selected']
        state['_target_report'] = report
    elif old and sni == old['sni'] and not args.sni:
        for field in ['target_ip','target_selection']:
            if field in old: state[field] = old[field]
    return state

def configs(s):
    endpoint = s.get('target_ip') or s['sni']
    if ':' in endpoint: endpoint = '[' + endpoint + ']'
    stream = {'network':'raw','security':'reality','realitySettings':{
        'show':False,'target':endpoint+':443','xver':0,'serverNames':[s['sni']],
        'privateKey':s['private_key'],'shortIds':[s['short_id']]}}
    server = {'log':{'loglevel':'warning'},'inbounds':[{
        'tag':'reality-in','listen':s['listen'],'port':s['port'],'protocol':'vless',
        'settings':{'clients':[{'id':s['uuid'],'flow':'xtls-rprx-vision'}],'decryption':'none'},
        'streamSettings':stream}],
        'outbounds':[{'tag':'direct','protocol':'freedom'},{'tag':'block','protocol':'blackhole'}],
        'routing':{'domainStrategy':'IPOnDemand','rules':[
            {'type':'field','ip':PRIVATE_NETS,'outboundTag':'block'}]}}
    client = {'log':{'loglevel':'warning'},'inbounds':[{
        'tag':'socks','listen':'127.0.0.1','port':10808,'protocol':'socks',
        'settings':{'auth':'noauth','udp':False}}],
        'outbounds':[{'tag':'proxy','protocol':'vless','settings':{
            'vnext':[{'address':s['server'],'port':s['port'],'users':[{
                'id':s['uuid'],'encryption':'none','flow':'xtls-rprx-vision'}]}]},
            'streamSettings':{'network':'raw','security':'reality','realitySettings':{
                'serverName':s['sni'],'fingerprint':'chrome','password':s['public_key'],
                'shortId':s['short_id'],'spiderX':'/'}},'mux':{'enabled':False}}]}
    query = urllib.parse.urlencode({'encryption':'none','security':'reality','sni':s['sni'],
        'fp':'chrome','pbk':s['public_key'],'sid':s['short_id'],
        'type':'tcp','flow':'xtls-rprx-vision','spx':'/'})
    host = '['+s['server']+']' if ':' in s['server'] else s['server']
    uri = f"vless://{s['uuid']}@{host}:{s['port']}?{query}#{urllib.parse.quote(s['name'],safe='')}"
    # JSON is valid YAML; avoid a YAML dependency and safely escape node names.
    mihomo = {'mixed-port':7890,'bind-address':'127.0.0.1','allow-lan':False,'mode':'rule','log-level':'warning',
        'proxies':[{'name':s['name'],'type':'vless','server':s['server'],'port':s['port'],
        'uuid':s['uuid'],'network':'tcp','tls':True,'udp':False,'flow':'xtls-rprx-vision',
        'servername':s['sni'],'client-fingerprint':'chrome','reality-opts':{
            'public-key':s['public_key'],'short-id':s['short_id']}}],
        'proxy-groups':[{'name':'PROXY','type':'select','proxies':[s['name']]}],
        'rules':['MATCH,PROXY']}
    return server, client, uri, mihomo

UNIT_TEXT = '''[Unit]
Description=VPS Proxy - Xray REALITY Vision
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=vps-proxy
Group=vps-proxy
ExecStart=/opt/vps-proxy/xray run -config /etc/vps-proxy/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
UMask=0077

[Install]
WantedBy=multi-user.target
'''

def emit_clients(s, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    _, client, uri, mihomo = configs(s)
    write(directory/'xray-client.json',dump(client))
    write(directory/'vless.txt',uri+'\n')
    write(directory/'mihomo.yaml',dump(mihomo))
    write(directory/'node-info.json',dump({k:v for k,v in s.items() if k != 'private_key'}))
    write(directory/'client-compatibility.json',dump(client_compatibility(s)))

def check_port(s, old, active):
    if active and old and s['listen'] == old['listen'] and s['port'] == old['port']: return
    family = socket.AF_INET6 if ':' in s['listen'] else socket.AF_INET
    with socket.socket(family,socket.SOCK_STREAM) as sock:
        try: sock.bind((s['listen'],s['port']))
        except OSError as e: fail(f"入口 {s['listen']}:{s['port']} 无法绑定（可能被占用）：{e}")

def load_state():
    if not (ETC/'state.json').exists(): fail('尚未部署，请先运行 install。')
    return json.loads((ETC/'state.json').read_text())

def active():
    return run(['systemctl','is-active','--quiet',SERVICE],check=False).returncode == 0

def install(args):
    with lock():
        deps()
        ETC.mkdir(mode=0o750,parents=True,exist_ok=True)
        STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
        os.chmod(STATE,0o700)
        old = load_state() if (ETC/'state.json').exists() else None
        if not old and (UNIT.exists() or BIN.exists() or (ETC/'config.json').exists()):
            fail('发现未受本脚本状态文件管理的同名安装；请先检查并迁移。')
        profile, chosen = deployment_settings(args, old)
        if profile == 'shadowrocket':
            print('Shadowrocket 兼容模式：使用较旧官方 v26.6.27，并验证新旧指纹。',flush=True)
        was_active = active()
        was_enabled = run(['systemctl','is-enabled','--quiet',SERVICE],check=False).returncode == 0
        with tempfile.TemporaryDirectory(prefix='vps-proxy-') as tmp:
            if old and chosen == old['version'] and BIN.exists():
                candidate = Path(tmp)/'xray'; shutil.copy2(BIN,candidate)
            else:
                candidate = download_xray(chosen,tmp)
            s = make_state(candidate,args,old)
            scan_report = s.pop('_target_report', None)
            checked_target = probe_target(s['sni'],s['server'],s.get('target_ip'))
            if checked_target: s['target_ip'] = checked_target['ip']
            if not scan_report and (not old or args.sni):
                s.pop('target_selection', None)
                scan_report = {'mode':'manual', 'selected':{
                    'domain':s['sni'], 'ip':s.get('target_ip')},
                    'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}

            if profile == 'shadowrocket':
                proof_row = {'domain':s['sni'],'ip':s['target_ip']}
                for fingerprint in ['chrome','hellochrome_120']:
                    print('兼容性校验：'+fingerprint,flush=True)
                    verify_reality_target(candidate,proof_row,s['private_key'],s['public_key'],fingerprint)
            check_port(s,old,was_active)
            server, client, _, _ = configs(s)
            for label, config in [('server',server),('client',client)]:
                file = Path(tmp)/(label+'.json'); write(file,dump(config))
                checked = run([candidate,'run','-test','-config',file])
                if label == 'server':
                    for line in (checked.stdout + checked.stderr).splitlines():
                        if '[Warning]' in line:
                            print('Xray 配置提示：' + line, flush=True)
            if run(['id','-u',USER],check=False).returncode:
                run(['useradd','--system','--user-group','--home-dir','/nonexistent',
                     '--no-create-home','--shell','/usr/sbin/nologin',USER])
            import grp
            gid = grp.getgrnam(USER).gr_gid
            backup = STATE/'backups'/(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+secrets.token_hex(3))
            backup.mkdir(parents=True,mode=0o700)
            managed = [BIN,UNIT,ETC/'config.json',ETC/'state.json',STATE/'target-selection.json']
            saved = {}
            for i,p in enumerate(managed):
                if p.exists():
                    dest = backup/str(i); shutil.copy2(p,dest)
                    st = p.stat(); saved[p]=(dest,st.st_uid,st.st_gid)
                else: saved[p]=None
            if (STATE/'clients').exists(): shutil.copytree(STATE/'clients',backup/'clients')
            write(backup/'manifest.json',dump({'paths':[str(p) for p in managed],
                'was_active':was_active,'was_enabled':was_enabled}))
            try:
                BIN.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                os.chmod(BIN.parent, 0o755)
                write(BIN,candidate.read_bytes(),0o755)
                write(ETC/'config.json',dump(server),0o640)
                os.chown(ETC,0,gid); os.chmod(ETC,0o750)
                os.chown(ETC/'config.json',0,gid)
                write(ETC/'state.json',dump(s))
                write(UNIT,UNIT_TEXT,0o644)
                run(['systemctl','daemon-reload'])
                run(['systemctl','enable',SERVICE])
                run(['systemctl','restart',SERVICE])
                time.sleep(2)
                if not active(): fail('服务启动后退出。可用 journalctl -u vps-proxy 检查。')
                family = socket.AF_INET6 if ':' in s['listen'] else socket.AF_INET
                host = ('::1' if s['listen']=='::' else s['listen']) if family==socket.AF_INET6 else ('127.0.0.1' if s['listen']=='0.0.0.0' else s['listen'])
                with socket.create_connection((host,s['port']),timeout=3): pass
                if scan_report: write(STATE/'target-selection.json', dump(scan_report))
                emit_clients(s,STATE/'clients')
            except BaseException:
                run(['systemctl','stop',SERVICE],check=False)
                for p, entry in saved.items():
                    if entry:
                        source,uid,gid0=entry
                        write(p,source.read_bytes(),source.stat().st_mode & 0o777)
                        os.chown(p,uid,gid0)
                    elif p.exists(): p.unlink()
                shutil.rmtree(STATE/'clients',ignore_errors=True)
                if (backup/'clients').exists(): shutil.copytree(backup/'clients',STATE/'clients')
                run(['systemctl','daemon-reload'],check=False)
                run(['systemctl','enable' if was_enabled else 'disable',SERVICE],check=False)
                if was_active: run(['systemctl','start',SERVICE],check=False)
                print('部署失败，已尝试恢复此前二进制、配置和服务状态。',file=sys.stderr)
                raise
            print(f"部署成功：{s['server']}:{s['port']}，Xray {s['version']}")
            print(f'客户端文件：{STATE}/clients/（root 可读）；备份：{backup}')
            print(f"请放行云安全组及主机防火墙 TCP {s['port']}；脚本不改动现有防火墙。")
            print('本机监听已验证；公网可达性与真实代理吞吐需从本地验证。')
            print('客户端兼容说明：'+client_compatibility(s)['note'])
        if args.optimize:
            try: tune_locked()
            except Exception as e: print(f'代理已部署；性能优化未完成：{e}',file=sys.stderr)

def sysget(key):
    return run(['sysctl','-n',key]).stdout.strip()

def tune_locked():
    STATE.mkdir(parents=True,mode=0o700,exist_ok=True)
    snap = STATE/'sysctl-before.json'
    if snap.exists(): fail('已存在优化记录。先 restore-tuning，再重新优化。')
    if TUNE.exists(): fail(f'{TUNE} 已存在但无对应备份，拒绝覆盖。')
    run(['modprobe','tcp_bbr'],check=False)
    run(['modprobe','sch_fq'],check=False)
    available = sysget('net.ipv4.tcp_available_congestion_control').split()
    # Preserve defaults and never lower any existing receive/send memory limit.
    desired = {'net.ipv4.tcp_moderate_rcvbuf':'1','net.ipv4.tcp_mtu_probing':'1'}
    if 'bbr' in available:
        desired['net.ipv4.tcp_congestion_control']='bbr'
        desired['net.core.default_qdisc']='fq'
    else: print('内核未提供 BBR，保留现有拥塞控制。')
    mem = int(re.search(r'MemTotal:\s+(\d+)',Path('/proc/meminfo').read_text())[1])*1024
    cap = 16*1024*1024 if mem >= 1024**3 else 4*1024*1024
    for k in ['net.core.rmem_max','net.core.wmem_max']:
        desired[k]=str(max(int(sysget(k)),cap))
    for k in ['net.ipv4.tcp_rmem','net.ipv4.tcp_wmem']:
        v = [int(x) for x in sysget(k).split()]
        desired[k]=' '.join(map(str,[v[0],v[1],max(v[2],cap)]))
    old={k:sysget(k) for k in desired}
    write(snap,dump(old))
    try:
        write(TUNE,'# Managed by vps-proxy; use restore-tuning\n'+''.join(f'{k} = {v}\n' for k,v in desired.items()),0o644)
        for k,v in desired.items(): run(['sysctl','-w',f'{k}={v}'])
    except BaseException:
        failed=[]
        for k,v in old.items():
            if run(['sysctl','-w',f'{k}={v}'],check=False).returncode: failed.append(k)
        TUNE.unlink(missing_ok=True)
        if not failed: snap.unlink()
        else: print('部分原值恢复失败，保留备份：'+str(snap),file=sys.stderr)
        raise
    print('性能配置已应用；影响整台 VPS 的新 TCP 连接，不保证提速。')
    print('fq 默认值不替换现有网卡队列；不重启网络、不修改 MTU、不安装内核。')
    print('恢复命令：sudo bash vps-proxy.sh restore-tuning')

def restore():
    with lock():
        snap=STATE/'sysctl-before.json'
        if not snap.exists(): fail('没有可恢复的优化备份。')
        old=json.loads(snap.read_text())
        for k,v in old.items(): run(['sysctl','-w',f'{k}={v}'])
        TUNE.unlink(missing_ok=True)
        write(STATE/'sysctl-last-restored.json',dump(old))
        snap.unlink()
        print('已恢复本脚本优化前的运行时值，并删除本脚本持久化配置。')

def check():
    root_linux()
    s=load_state()
    print(f"节点：{s['name']} / {s['server']}:{s['port']} / {s['version']}")
    run([BIN,'run','-test','-config',ETC/'config.json'])
    print('配置检查：通过；服务：'+('运行中' if active() else '未运行'))
    print('REALITY 目标：'+s['sni']+' → '+s.get('target_ip','随域名解析'))
    print(run(['ss','-lntp',f'sport = :{s["port"]}']).stdout.strip())
    print('拥塞控制：'+sysget('net.ipv4.tcp_congestion_control'))
    print('可用拥塞控制：'+sysget('net.ipv4.tcp_available_congestion_control'))
    print('系统默认队列：'+sysget('net.core.default_qdisc'))
    print('TCP 计数（主机累计值，需比较测速前后差值）：')
    print(run(['ss','-s']).stdout)
    print('防火墙/安全组及客户端连通性需从外部核验。')

def benchmark(args):
    if not shutil.which('curl'): fail('测速需要 curl。')
    url=args.url
    if urllib.parse.urlparse(url).scheme != 'https': fail('测速 URL 必须使用 HTTPS。')
    if not 1 <= args.streams <= 16 or not 5 <= args.seconds <= 120:
        fail('--streams 为 1—16，--seconds 为 5—120。')
    proxy=args.proxy
    if proxy:
        u=urllib.parse.urlparse(proxy)
        if u.scheme not in ['socks5h','http','https'] or not u.hostname or not u.port:
            fail('--proxy 示例：socks5h://127.0.0.1:10808')
    mode='经指定代理（在本地运行才包含本地跨境路径）' if proxy else '直连（在 VPS 运行仅测 VPS 出口）'
    print('测速路径：'+mode)
    print(f'先单连接，再 {args.streams} 并发；默认最多下载约 {(1+args.streams)*32} MiB。自定义 URL 的流量由文件大小与时限决定。')
    def one():
        cmd=['curl','--silent','--show-error','--location','--fail','--http1.1',
             '--proto','=https','--proto-redir','=https','--connect-timeout','10',
             '--max-time',str(args.seconds),'--output',os.devnull,
             '--write-out','%{http_code} %{size_download} %{time_total} %{time_connect} %{time_starttransfer}']
        # Make the measured path independent of environment proxy variables / NO_PROXY.
        cmd += ['--proxy',proxy or '', '--noproxy','' if proxy else '*']
        r=run(cmd+[url],check=False,timeout=args.seconds+15)
        fields=r.stdout.split()
        if len(fields)!=5: return {'ok':False,'error':'curl 未返回有效统计','exit':r.returncode}
        code,size,total,connect,ttfb=fields
        size=float(size)
        ok=code=='200' and size>0 and r.returncode in (0,28)
        return {'ok':ok,'http':code,'bytes':int(size),'seconds':float(total),
                'connect_s':float(connect),'ttfb_s':float(ttfb),'partial':r.returncode==28,
                'exit':r.returncode,'error':r.stderr[-300:] if not ok else ''}
    results=[]
    for count in [1,args.streams]:
        start=time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=count) as ex:
            samples=list(ex.map(lambda _:one(),range(count)))
        elapsed=time.monotonic()-start
        good=[x for x in samples if x['ok']]
        mbps=sum(x['bytes'] for x in good)*8/elapsed/1e6
        row={'streams':count,'valid_streams':len(good),'wall_seconds':round(elapsed,3),
             'aggregate_mbps':round(mbps,2),'samples':samples}
        results.append(row)
        state='通过' if len(good)==count else '失败/不完整'
        print(f'{count} 连接：{mbps:.2f} Mbps，成功 {len(good)}/{count}，{state}')
        if any(x.get('partial') for x in samples): print('  含达到时限的部分下载；速率按已接收字节计算。')
    report={'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'mode':mode,'url':url,'results':results}
    # Never persist proxy URI: it may contain credentials.
    if args.output: write(Path(args.output),dump(report))
    if not all(x['valid_streams']==x['streams'] for x in results):
        fail('存在失败连接；检查报告，勿把此结果直接作为链路容量。')

def self_test():
    import unittest
    class Tests(unittest.TestCase):
        def sample(self):
            return dict(server='203.0.113.7',sni='www.microsoft.com',port=443,listen='0.0.0.0',
                name='节点 "测试" / A',uuid=str(uuid.uuid4()),private_key='private-sentinel',
                public_key='public-sentinel',short_id=secrets.token_hex(8),version=VERSION)
        def test_exports(self):
            s=self.sample()
            with tempfile.TemporaryDirectory() as d:
                emit_clients(s,d)
                for p in Path(d).iterdir():
                    self.assertNotIn(s['private_key'],p.read_text())
                    self.assertEqual(p.stat().st_mode & 0o777,0o600)
                c=json.loads((Path(d)/'xray-client.json').read_text())
                self.assertEqual(c['inbounds'][0]['listen'],'127.0.0.1')
                self.assertFalse(c['outbounds'][0]['mux']['enabled'])
                self.assertEqual(json.loads((Path(d)/'mihomo.yaml').read_text())['proxies'][0]['name'],s['name'])
        def test_ipv6_uri(self):
            s=self.sample();s['server']='2001:db8::1'
            uri=configs(s)[2]; u=urllib.parse.urlparse(uri)
            self.assertEqual(u.hostname,s['server']);self.assertEqual(u.port,443)
            self.assertEqual(urllib.parse.parse_qs(u.query)['pbk'],[s['public_key']])
        def test_host_validation(self):
            for host in ['example.com','192.0.2.1','2001:db8::1']: valid_host(host)
            for host in ['https://evil.com','a\nb','a;touch /tmp/x','a.com:443','a@b']:
                with self.assertRaises(RuntimeError): valid_host(host)
        def test_atomic_write(self):
            with tempfile.TemporaryDirectory() as d:
                p=Path(d)/'a';write(p,'first');write(p,'second')
                self.assertEqual(p.read_text(),'second');self.assertEqual(len(list(Path(d).iterdir())),1)
        def test_independent_ids(self):
            a=self.sample(); b=self.sample()
            self.assertNotEqual(a['uuid'],b['uuid']); self.assertNotEqual(a['short_id'],b['short_id'])
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    if not result.wasSuccessful(): sys.exit(1)

def main():
    p=argparse.ArgumentParser(description='多 VPS 通用 REALITY + Vision 部署、客户端导出、测速与可回滚调优')
    sub=p.add_subparsers(dest='command')
    i=sub.add_parser('install',help='首次部署 / 保留凭据重新部署；变更版本可指定 --version')
    i.add_argument('--server',help='公网 IP 或域名；缺省自动检测 IPv4，重跑沿用')
    target_group = i.add_mutually_exclusive_group()
    target_group.add_argument('--sni',help='手动指定目标域名；默认首次自动筛选、重跑沿用')
    target_group.add_argument('--reselect-target',action='store_true',help='保留密钥，重新筛选目标；客户端 SNI 可能变化')
    i.add_argument('--candidates-file',help='自定义候选域名文件，每行一个；仅自动筛选时使用')
    i.add_argument('--no-asn',action='store_true',help='不向 RIPEstat 查询 ASN，仅按兼容性与延迟筛选')
    i.add_argument('--port',type=int)
    i.add_argument('--listen',help='缺省 0.0.0.0；IPv6 使用 ::')
    i.add_argument('--name',help='客户端节点名称')
    i.add_argument('--version',help=f'固定版本；modern 缺省 {VERSION}，重跑沿用已装版本')
    i.add_argument('--client-profile',choices=['modern','shadowrocket'],help='默认 modern；shadowrocket 使用已做新旧指纹对照的较旧官方 v26.6.27；重跑沿用')
    i.add_argument('--optimize',action='store_true',help='部署后应用可恢复的主机 TCP 调优')
    sub.add_parser('optimize',help='应用 TCP 调优（先保存原值）')
    sub.add_parser('restore-tuning',help='恢复本脚本优化前的主机 TCP 参数')
    sub.add_parser('check',help='检查配置、服务、监听和主机 TCP 状态')
    e=sub.add_parser('export',help='根据当前状态重新导出客户端配置')
    e.add_argument('--output',help='导出目录；缺省 /var/lib/vps-proxy/clients')
    b=sub.add_parser('bench',help='本地/VPS HTTPS 单连接与并发下载测速，无需 root')
    b.add_argument('--proxy',help='例如 socks5h://127.0.0.1:10808；不填则直连')
    b.add_argument('--url',default=TEST_URL)
    b.add_argument('--streams',type=int,default=4)
    b.add_argument('--seconds',type=int,default=30)
    b.add_argument('--output',help='可选 JSON 报告路径')
    scan = sub.add_parser('scan-targets',help='只检测候选域名并生成报告，不部署、不切换服务')
    scan.add_argument('--server',help='VPS 公网 IP/域名；不填则检测公网 IPv4')
    scan.add_argument('--candidates-file',help='每行一个域名；提供后替换内置列表')
    scan.add_argument('--xray',help='本机 Xray 二进制路径；已部署时自动使用本脚本安装的核心')
    scan.add_argument('--no-asn',action='store_true',help='跳过外部 ASN 查询')
    scan.add_argument('--output',help='JSON 报告路径（含排除原因）')
    sub.add_parser('self-test',help='运行纯本地自检，不修改服务器')
    args=p.parse_args()
    if args.command=='install': install(args)
    elif args.command=='optimize':
        with lock(): tune_locked()
    elif args.command=='restore-tuning': restore()
    elif args.command=='check': check()
    elif args.command=='export':
        with lock():
            dest=Path(args.output) if args.output else STATE/'clients'
            emit_clients(load_state(),dest);print('已导出到 '+str(dest))
    elif args.command=='bench': benchmark(args)
    elif args.command=='scan-targets':
        binary = Path(args.xray).resolve() if args.xray else (BIN if BIN.exists() else None)
        if binary and not os.access(binary,os.X_OK): fail('指定 Xray 不存在或不可执行。')
        if not binary: print('未提供 Xray：报告仅含 TLS/网络检测；安装时还会进行核心检查。',flush=True)
        report = scan_targets(valid_host(args.server or detect_server()),args.candidates_file,binary,not args.no_asn)
        if args.output: write(Path(args.output),dump(report))
        if not report['selected']: fail('所有候选均不合格，请检查报告或更换候选文件。')
    elif args.command=='self-test': self_test()
    else: p.print_help()

if __name__=='__main__':
    os.umask(0o077)
    try: main()
    except KeyboardInterrupt:
        print('已中断。',file=sys.stderr);sys.exit(130)
    except Exception as e:
        print('错误：'+str(e),file=sys.stderr);sys.exit(1)
PY

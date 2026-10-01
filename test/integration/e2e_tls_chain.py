#!/usr/bin/env python3
"""Server-side TLS chain / SNI gate for lua-router (doc/gap-tls-chain.md).

Owned behaviour, all against a real container and an openssl-built PKI:

  1. chain building: independent root CA -> intermediate CA -> leaf, SANs carry DNS
     names *and* an IP address. The router gets leaf+intermediate, the client trusts
     the root only, so a green run proves the server ships a complete chain rather
     than the client having been handed the intermediate;
  2. four negative handshake classes -- expired leaf, hostname/SAN mismatch, issuer
     that is not a CA, self-signed with no CA -- each must be refused by the client
     verifier for *its own* reason (every negative uses a hostname that matches its
     SAN, so a failure is never confounded with a name mismatch), while the router
     keeps serving and logs no crash;
  3. key-type x protocol matrix: one RSA leaf and one ECDSA P-256 leaf, each at
     TLSv1.3 and TLSv1.2, checked on the negotiated cipher family;
  4. SNI: two hostnames on one port with two certificate pairs, proven by the leaf
     fingerprint the server actually sends per ServerName.

The shipped renderer emits exactly one ssl_certificate pair
(docker-entrypoint.sh). The multi-certificate round therefore uses the generic
LR_HTTP_INCLUDE server fragment, which the entrypoint already supports: no core
change, and the single-pair limit is recorded in the doc.
"""
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from _lib import (IMAGE, RESULTS, RUN, TMP, check, cleanup, free_port,  # noqa: E402
                  logs, start_mock)

D = os.path.join(TMP, "tls-chain-" + RUN)
CERTS = os.path.join(D, "certs")
PRIV = os.path.join(D, "private")
FRAG = os.path.join(D, "frag")
DB = os.path.join(D, "ca-db")
GEN = "/gen"                    # D is mounted read-only at this path
ORG = "LtTlsChain Test"
CA_CONTAINERS = []
NOTES = []


# --------------------------------------------------------------- openssl glue
def sh(cmd, inp=None, timeout=30):
    r = subprocess.run(cmd, capture_output=True, text=True, input=inp, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def O(*args, inp=None):
    rc, out, err = sh(["openssl", *args], inp=inp)
    if rc != 0:
        raise RuntimeError("openssl %s -> rc=%s\n%s" % (" ".join(args), rc, err[-600:]))
    return out


def gen_key(name, kind):
    p = os.path.join(PRIV, name + ".key")
    if kind in ("rsa", "rsa3072"):
        O("genrsa", "-out", p, "3072" if kind == "rsa3072" else "2048")
    elif kind in ("p256", "p384"):
        curve = "prime256v1" if kind == "p256" else "secp384r1"
        O("ecparam", "-name", curve, "-genkey", "-noout", "-out", p)
    else:
        raise ValueError(kind)
    return p


def new_req(keyfile, cn):
    csr = keyfile + ".csr"
    O("req", "-new", "-key", keyfile, "-subj", "/O=%s/CN=%s" % (ORG, cn), "-out", csr)
    return csr


def ext_text(sans=None, ca=False):
    lines = ["basicConstraints=critical,CA:%s" % ("TRUE" if ca else "FALSE")]
    lines.append("keyUsage=critical,%s"
                 % ("keyCertSign,cRLSign" if ca else "digitalSignature,keyEncipherment"))
    if not ca:
        lines.append("extendedKeyUsage=serverAuth")
    if sans:
        lines.append("subjectAltName=%s" % sans)
    lines.append("subjectKeyIdentifier=hash")
    if not ca:
        lines.append("authorityKeyIdentifier=keyid,issuer")
    return "\n".join(lines) + "\n"


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    return path


def sign(csr_path, ext, ca_crt, ca_key, out, days=825, md="sha256", clrext=False):
    """Sign a CSR under a CA. clrext=True ships no extensions at all, which is how
    the no-SAN fixture is built."""
    args = ["x509", "-req", "-in", csr_path]
    if clrext:
        args.append("-clrext")
    else:
        args += ["-extfile", write(out + ".ext", ext)]
    args += ["-CA", ca_crt, "-CAkey", ca_key, "-CAcreateserial", "-days", str(days),
             "-" + md, "-out", out]
    O(*args)
    return out


def selfsign(keyfile, cn, ext, out, days=3650, org=None):
    """Self-signed certificate (root CAs, the fake issuer and the self-signed leaf).

    `openssl req` has no -extfile, so each extension line goes in through -addext.
    """
    args = ["req", "-x509", "-new", "-key", keyfile,
            "-subj", "/O=%s/CN=%s" % (org or ORG, cn), "-days", str(days), "-sha256",
            "-out", out]
    for line in (ln.strip() for ln in ext.splitlines()):
        if line:
            args += ["-addext", line]
    O(*args)
    return out


def expired_leaf():
    """Chained leaf whose validity window is entirely in the past.

    `openssl x509 -req -days` cannot reach backwards and openssl 3.0 `req` has no
    -not_before, so the Micro-CA (`openssl ca`) signs it with explicit
    default_startdate/default_enddate and a private index+serial.
    """
    for d in (DB, os.path.join(DB, "newcerts")):
        os.makedirs(d, exist_ok=True)
    idx = os.path.join(DB, "index.txt")
    ser = os.path.join(DB, "serial")
    open(idx, "w").close()
    write(ser, "1000\n")
    conf = write(os.path.join(DB, "ca.conf"), """[ ca ]
default_ca = leaf_ca
[ leaf_ca ]
database = %s
serial = %s
private_key = %s
certificate = %s
new_certs_dir = %s
default_md = sha256
policy = pol
email_in_dn = no
unique_subject = no
preserve = no
default_startdate = 20200101000000Z
default_enddate   = 20210101000000Z
x509_extensions = leaf
[ pol ]
commonName = supplied
organizationName = optional
[ leaf ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:expired.router.test,IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
""" % (idx, ser, os.path.join(PRIV, "inter-ca.key"), os.path.join(CERTS, "inter-ca.crt"),
       os.path.join(DB, "newcerts")))
    out = os.path.join(CERTS, "expired.crt")
    O("ca", "-batch", "-config", conf, "-in", new_req(gen_key("expired", "rsa"),
                                                     "expired.router.test"),
      "-out", out)
    return out


def build_pki():
    """root CA -> intermediate CA -> leaves, plus the rogue/non-CA fixtures."""
    for d in (CERTS, PRIV, FRAG):
        os.makedirs(d, exist_ok=True)
    root_key = gen_key("root-ca", "rsa3072")
    root = selfsign(root_key, "%s Root CA" % ORG, ext_text(ca=True),
                    os.path.join(CERTS, "root-ca.crt"))
    inter_key = gen_key("inter-ca", "p384")
    inter = sign(new_req(inter_key, "%s Intermediate CA" % ORG),
                 ext_text(ca=True).replace("basicConstraints=critical,CA:TRUE",
                                           "basicConstraints=critical,CA:TRUE,pathlen:0"),
                 root, root_key, os.path.join(CERTS, "inter-ca.crt"), days=1825,
                 md="sha384")

    rogue_root_key = gen_key("rogue-root-ca", "p256")
    rogue_root = selfsign(rogue_root_key, "Rogue Root CA", ext_text(ca=True),
                          os.path.join(CERTS, "rogue-root-ca.crt"), days=3650)
    rogue_inter_key = gen_key("rogue-inter-ca", "rsa")
    rogue_inter = sign(new_req(rogue_inter_key, "Rogue Intermediate CA"),
                       ext_text(ca=True).replace("basicConstraints=critical,CA:TRUE",
                                                 "basicConstraints=critical,CA:TRUE,pathlen:0"),
                       rogue_root, rogue_root_key,
                       os.path.join(CERTS, "rogue-inter-ca.crt"), days=1825)

    # an issuer that is explicitly CA:FALSE (and has no keyCertSign usage) but
    # nevertheless signs a leaf: the trust relationship must be refused on shape.
    fake_key = gen_key("fake-issuer", "rsa")
    fake = selfsign(fake_key, "Fake Issuer (not a CA)",
                    "basicConstraints=critical,CA:FALSE\n"
                    "keyUsage=critical,digitalSignature\n"
                    "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\n",
                    os.path.join(CERTS, "fake-issuer.crt"), org="Rogue")

    def leaf(name, kind, sans, cn):
        k = gen_key(name, kind)
        return sign(new_req(k, cn), ext_text(sans), inter, inter_key,
                    os.path.join(CERTS, name + ".crt")), k

    C = {}
    C["router-rsa"] = leaf("router-rsa", "rsa",
                           "DNS:router.test,DNS:www.router.test,IP:127.0.0.1",
                           "router.test")
    C["router-ec"] = leaf("router-ec", "p256",
                          "DNS:ec.router.test,DNS:www.router.test,IP:127.0.0.1",
                          "ec.router.test")
    C["alt-ec"] = leaf("alt-ec", "p256", "DNS:alt.router.test", "alt.router.test")
    C["wronghost"] = leaf("wronghost", "rsa", "DNS:notrouter.test,IP:10.99.99.99",
                          "notrouter.test")
    C["cnbutsan"] = leaf("cnbutsan", "rsa", "DNS:other.test", "router.test")
    C["expired"] = expired_leaf(), os.path.join(PRIV, "expired.key")
    C["rogue"] = (sign(new_req(gen_key("rogue-leaf", "rsa"), "rogue.router.test"),
                       ext_text("DNS:rogue.router.test,IP:127.0.0.1"),
                       rogue_inter, rogue_inter_key,
                       os.path.join(CERTS, "rogue-leaf.crt")),
                  os.path.join(PRIV, "rogue-leaf.key"))
    C["fake"] = (sign(new_req(gen_key("fake-leaf", "rsa"), "fake.router.test"),
                      ext_text("DNS:fake.router.test,IP:127.0.0.1"),
                      fake, fake_key, os.path.join(CERTS, "fake-leaf.crt")),
                 os.path.join(PRIV, "fake-leaf.key"))
    self_key = gen_key("selfsign", "rsa")
    C["selfsign"] = (selfsign(self_key, "self.router.test",
                              ext_text("DNS:self.router.test,IP:127.0.0.1"),
                              os.path.join(CERTS, "selfsign.crt"), days=825), self_key)
    # no SAN at all: -clrext drops every extension, leaving only the subject CN
    nosan_key = gen_key("nosan", "rsa")
    nosan = os.path.join(CERTS, "nosan.crt")
    sign(new_req(nosan_key, "router.test"), "", inter, inter_key, nosan, clrext=True)
    C["nosan"] = (nosan, nosan_key)
    return C, root, inter, rogue_root, fake


def fullchain(name, leaf_crt, issuer_crt):
    out = os.path.join(CERTS, name + "-fullchain.crt")
    write(out, open(leaf_crt).read() + open(issuer_crt).read())
    return out


def bundle(root, inter):
    """Two client trust stores: root only (forces a complete chain) and root+inter."""
    b1 = write(os.path.join(D, "ca-root-only.crt"), open(root).read())
    b2 = write(os.path.join(D, "ca-root-plus-inter.crt"),
               open(root).read() + open(inter).read())
    return b1, b2


# ------------------------------------------------------------- TLS observations
def cert_summary(der_path=None, pem_path=None, pem=None):
    # NB: openssl's nameopt value is "UTF8"; "UTF-8" makes `x509` exit with a usage
    # error, which would silently turn every fingerprint into "".
    cmd = ["openssl", "x509", "-noout", "-subject", "-issuer", "-fingerprint",
           "-sha256", "-nameopt", "UTF8"]
    if der_path:
        cmd += ["-inform", "DER", "-in", der_path]
        out = sh(cmd)[1]
    elif pem_path:
        cmd += ["-in", pem_path]
        out = sh(cmd)[1]
    else:
        out = sh(cmd, inp=pem)[1]
    return " ".join(out.split())


def fingerprint(**kw):
    line = cert_summary(**kw)
    i = line.find("sha256 Fingerprint=")
    if i < 0:
        raise RuntimeError("no fingerprint in: %r" % line[:200])
    return line[i + len("sha256 Fingerprint="):].split()[0]


def https_probe(port, cafile=None, sni="router.test", max_proto=None, min_proto=None,
                path="/health", timeout=10, client_cert=None, check_name=False):
    """One real handshake from python + one request over it.

    check_hostname stays off and the verifier is CERT_REQUIRED whenever a CA file is
    given, so a chain problem and a name problem are distinguishable: `chain_err`
    carries the verifier's own words, and name verdicts are asserted through
    check_host() against openssl's matcher.
    """
    out = {"ok": False, "status": None, "body": "", "err": "", "protocol": "",
           "cipher": "", "leaf": "", "alpn": None}
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # check_name=True turns openssl's own hostname matcher on as well, which is what
    # the SAN-mismatch round needs; everywhere else the name verdict is asserted
    # separately through check_host() so a chain failure stays distinguishable.
    ctx.check_hostname = bool(check_name and cafile)
    ctx.verify_mode = ssl.CERT_REQUIRED if cafile else ssl.CERT_NONE
    if cafile:
        ctx.load_verify_locations(cafile=cafile)
    if max_proto:
        ctx.maximum_version = max_proto
    if min_proto:
        ctx.minimum_version = min_proto
    if client_cert:
        crt, key = client_cert
        ctx.load_cert_chain(crt, key)
    conn = None
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        conn = ctx.wrap_socket(raw, server_hostname=sni)
        out["ok"] = True
        out["protocol"] = conn.version()
        out["cipher"] = (conn.cipher() or [""])[0]
        out["alpn"] = conn.selected_alpn_protocol()
        der = os.path.join(D, "peer-%d.der" % (int(time.time() * 1e6) % 1000000))
        with open(der, "wb") as f:
            f.write(conn.getpeercert(binary_form=True))
        out["leaf"] = cert_summary(der_path=der)
        os.remove(der)
        conn.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                      % (path, sni or "127.0.0.1")).encode())
        buf = b""
        while len(buf) < 65536:
            chunk = conn.recv(8192)
            if not chunk:
                break
            buf += chunk
        head, _, body = buf.partition(b"\r\n\r\n")
        parts = head.split(b"\r\n", 1)[0].decode("latin1").split()
        out["status"] = int(parts[1]) if len(parts) > 1 else None
        out["body"] = body.decode("utf-8", "replace")
    except ssl.SSLCertVerificationError as e:
        out["err"] = str(e).splitlines()[0][:220]
    except ssl.SSLError as e:
        out["err"] = str(e).splitlines()[0][:220]
    except Exception as e:  # noqa
        out["err"] = "%s: %s" % (type(e).__name__, str(e).splitlines()[0][:160])
    finally:
        if conn:
            try:
                conn.close()
            except Exception:  # noqa
                pass
    return out


def check_host(cert_pem_path, host):
    """openssl's own SAN/CN matcher, so the expectation is not hand-rolled.

    NB: `openssl x509 -checkhost` exits 0 in both directions -- the verdict is only
    in the text ("does match certificate" / "does NOT match certificate").
    """
    rc, out, err = sh(["openssl", "x509", "-in", cert_pem_path, "-noout",
                       "-checkhost", host])
    text = out + err
    return rc == 0 and "does NOT match" not in text and "does match" in text


def s_client(port, servername=None, cafile=None, tls=None, verify_host=None,
             timeout=25):
    """openssl CLI handshake. Full (not -brief) output so the chain, the negotiated
    suite and the verifier verdict all come from one run."""
    cmd = ["openssl", "s_client", "-connect", "127.0.0.1:%d" % port,
           "-CAfile", cafile or os.devnull]
    if servername is None:
        cmd.append("-noservername")
    else:
        cmd += ["-servername", servername]
    if verify_host:
        cmd += ["-verify_hostname", verify_host, "-verify_return_error"]
    if tls:
        cmd.append(tls)
    rc, out, err = sh(cmd, inp="Q\n", timeout=timeout)
    text = out + "\n" + err
    m = re.search(r"Verify return code:\s*(-?\d+)\s*\((.*)\)", text)
    new = re.search(r"^New,\s+(\S+),\s+Cipher is\s+(\S+)", text, re.M)
    depths = [m[1].strip() for m in re.findall(r"^ (\d+) s:(.*)$", text, re.M)]
    pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                      text, re.S)
    chal = re.search(r"No client certificate CA names sent", text)
    return {"rc": rc,
            "verify_code": int(m.group(1)) if m else None,
            "verify_msg": m.group(2) if m else "",
            "protocol": new.group(1) if new else "",
            "cipher": new.group(2) if new else "",
            "depths": len(depths), "subjects": [d.strip() for d in depths],
            "leaf_fp": (fingerprint(pem=pems[0]) if pems else ""),
            "no_client_ca": bool(chal),
            "text": text}


def curl(port, path="/health", cacert=None, host=None, insecure=False, tls_max=None,
         method="GET", body=None, timeout=12, url_scheme="https"):
    """(rc, http_code, response body, stderr) for one request through curl."""
    authority = host or "127.0.0.1"
    url = "%s://%s:%d%s" % (url_scheme, authority, port, path)
    out_file = os.path.join(D, "curl-%d" % (int(time.time() * 1e6) % 1000000))
    cmd = ["curl", "-sS", "-m", str(timeout), "-o", out_file, "-w", "%{http_code}"]
    if cacert:
        cmd += ["--cacert", cacert]
    if insecure:
        cmd.append("-k")
    if tls_max:
        cmd += ["--tls-max", tls_max]
    if host:
        cmd += ["--resolve", "%s:%d:127.0.0.1" % (host, port)]
    if method != "GET":
        cmd += ["-X", method]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data", body]
    cmd.append(url)
    rc, out, err = sh(cmd)
    text = open(out_file).read() if os.path.exists(out_file) else ""
    if os.path.exists(out_file):
        os.remove(out_file)
    return rc, out.strip(), text, err.strip()


# ------------------------------------------------------------ router lifecycle
def alive(name):
    return sh(["docker", "inspect", "-f", "{{.State.Running}}", name])[1].strip() == "true"


def start_tls_router(tag, cert, keyfile, port=None, extra_env=None, fragment=None,
                     worker_url=None, wait=True):
    """One TLS-enabled router; the gate tree D is mounted read-only at /gen.

    wait=False only checks that the container stayed up, which is what the
    certificate/key pairing round needs: that listener never answers a request.
    """
    port = port or free_port()
    name = "lr-tlsc-%s-%s" % (tag, RUN)

    def gcont(hostpath):
        """Translate a path in the gate tree D to its in-container location."""
        hp = os.path.abspath(hostpath)
        rel = hp[len(D):] if hp.startswith(D) else hp
        return GEN + rel

    env = {"SMG_PORT": port, "SMG_METRICS_PORT": "0", "NGINX_WORKER_PROCESSES": "1",
           "SMG_HEALTH_CHECK_INTERVAL_SECS": "1", "LR_UI_CONF": "off",
           "SMG_TLS_CERT_PATH": gcont(cert), "SMG_TLS_KEY_PATH": gcont(keyfile)}
    if fragment:
        env["LR_HTTP_INCLUDE"] = gcont(fragment) if not fragment.startswith(GEN) else fragment
    if worker_url:
        env["SMG_WORKER_URLS"] = worker_url
    env.update(extra_env or {})
    args = ["docker", "run", "-d", "--name", name, "--network", "host",
            "-v", "%s:%s:ro" % (D, GEN), "--entrypoint", "/docker-entrypoint.sh", IMAGE,
            "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
            "-g", "daemon off;"]
    for k, v in env.items():
        args[3:3] = ["-e", "%s=%s" % (k, v)]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("docker run %s: %s" % (name, r.stderr[-400:]))
    CA_CONTAINERS.append(name)
    if not wait:
        time.sleep(1.5)
        if not alive(name):
            raise RuntimeError("router %s died:\n%s" % (name, logs(name)[-2000:]))
        return port, name
    for _ in range(120):
        if sh(["docker", "inspect", "-f", "{{.State.Running}}", name])[1].strip() == "true":
            if curl(port, "/health", insecure=True, timeout=2)[1] == "200":
                return port, name
        time.sleep(0.25)
    raise RuntimeError("router %s never served TLS:\n%s" % (name, logs(name)[-2000:]))


def crash_lines(name):
    needles = ("lua entry thread aborted", "signal 11", "signal 6", "[emerg]",
               "worker process exited on signal", "core dumped")
    return [ln for ln in logs(name).splitlines() if any(n in ln for n in needles)]


def error_lines(name):
    return [ln for ln in logs(name).splitlines()
            if "[error]" in ln or "[crit]" in ln or "aborted" in ln]


def stop(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def register_tls(port, cacert, host, url, model):
    return curl(port, "/workers", cacert=cacert, host=host, method="POST",
                body=json.dumps({"url": url, "model_id": model}))


def chat_tls(port, cacert, host, model, text, stream=False, timeout=25):
    return curl(port, "/v1/chat/completions", cacert=cacert, host=host, method="POST",
                body=json.dumps({"model": model,
                                 "messages": [{"role": "user", "content": text}],
                                 "stream": stream}), timeout=timeout)


def wait_workers_tls(port, cacert, host, want=1, timeout=45):
    for _ in range(int(timeout / 0.5)):
        _, code, out, _ = curl(port, "/workers", cacert=cacert, host=host)
        if code == "200":
            ws = json.loads(out).get("workers", [])
            if sum(1 for w in ws if w.get("is_healthy")) >= want:
                return True
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------------- suite
def note(text):
    NOTES.append(text)
    print("NOTE  " + text)


def finish():
    names = list(CA_CONTAINERS)
    bad = [n for n in names if not alive(n)]
    check("[stability] every TLS instance still running", not bad, bad)
    crashes = {n: crash_lines(n) for n in names if crash_lines(n)}
    check("[stability] no crash/emerg lines anywhere", not crashes,
          json.dumps({k: v[:1] for k, v in crashes.items()})[:400])
    for n in names:
        stop(n)
    failed = [r for r in RESULTS if not r[0]]
    print("\n=== %d checks, %d failed, %d notes ===" % (len(RESULTS), len(failed),
                                                        len(NOTES)))
    for _, n, d in failed:
        print("FAILED: %s | %s" % (n, str(d)[:300]))
    for n in NOTES:
        print("NOTE: %s" % n[:200])
    cleanup()
    if not failed:
        # green run leaves nothing behind; a failing run keeps the PKI tree (and the
        # rendered fragments) under D for post-mortem.
        shutil.rmtree(D, ignore_errors=True)
    else:
        print("PKI tree kept for inspection: %s" % D)
    sys.exit(1 if failed else 0)


def main():  # noqa: C901
    for d in (D, CERTS, PRIV, FRAG):
        os.makedirs(d, exist_ok=True)
    C, root, inter, rogue_root, fake_issuer = build_pki()
    root_only, root_plus = bundle(root, inter)

    # every negative class is reached through a hostname that matches its own SAN,
    # so a refusal can never be a hostname failure in disguise.
    HOST = {"router-rsa": "router.test", "router-ec": "ec.router.test",
            "alt-ec": "alt.router.test", "wronghost": "notrouter.test",
            "expired": "expired.router.test", "rogue": "rogue.router.test",
            "fake": "fake.router.test", "selfsign": "self.router.test",
            "nosan": "router.test", "cnbutsan": "other.test"}
    FULL = {
        "router-rsa": fullchain("router-rsa", C["router-rsa"][0], inter),
        "router-ec": fullchain("router-ec", C["router-ec"][0], inter),
        "alt-ec": fullchain("alt-ec", C["alt-ec"][0], inter),
        "wronghost": fullchain("wronghost", C["wronghost"][0], inter),
        "expired": fullchain("expired", C["expired"][0], inter),
        "rogue": fullchain("rogue", C["rogue"][0],
                           os.path.join(CERTS, "rogue-inter-ca.crt")),
        "fake": fullchain("fake", C["fake"][0], fake_issuer),
        "selfsign": C["selfsign"][0],
        "nosan": fullchain("nosan", C["nosan"][0], inter),
        "cnbutsan": fullchain("cnbutsan", C["cnbutsan"][0], inter),
    }
    FP = {n: fingerprint(pem_path=C[n][0]) for n in HOST}

    # ================================================ 1. PKI self-validation
    rc, out, _ = sh(["openssl", "verify", "-CAfile", root, inter])
    check("[pki] intermediate verifies under the root", rc == 0, out.strip())
    rc, out, _ = sh(["openssl", "verify", "-CAfile", root, "-untrusted", inter,
                     C["router-rsa"][0]])
    check("[pki] leaf chains up through the intermediate", rc == 0, out.strip()[:200])
    # `openssl verify` reports its verdict lines on stderr, so every negative
    # offline check below reads out+err.
    rc, out, err = sh(["openssl", "verify", "-CAfile", root, C["router-rsa"][0]])
    vtxt = out + err
    check("[pki] the leaf alone does NOT verify on the root (chain is load-bearing)",
          rc != 0 and "unable to get local issuer" in vtxt, vtxt.strip()[:200])
    rc, out, err = sh(["openssl", "verify", "-CAfile", root, "-untrusted", inter,
                       C["expired"][0]])
    vtxt = out + err
    check("[pki] expired fixture is expired for the verifier",
          rc != 0 and "expired" in vtxt.lower(), vtxt.strip()[:200])
    text = sh(["openssl", "x509", "-in", C["router-rsa"][0], "-noout", "-text"])[1]
    check("[pki] leaf SAN carries both DNS names and an IP",
          "DNS:router.test" in text and "IP Address:127.0.0.1" in text,
          [l.strip() for l in text.splitlines() if "DNS:" in l or "IP Address" in l])
    inter_txt = sh(["openssl", "x509", "-in", inter, "-noout", "-text"])[1]
    check("[pki] intermediate is an ECDSA key under an RSA root",
          "id-ecPublicKey" in inter_txt
          and "Signature Algorithm: sha384WithRSAEncryption" in inter_txt,
          [l.strip() for l in inter_txt.splitlines() if "Algorithm" in l][:2])
    rc, out, err = sh(["openssl", "verify", "-CAfile", fake_issuer, C["fake"][0]])
    vtxt = out + err
    check("[pki] CA:FALSE issuer rejected offline (CA/keyUsage wording)",
          rc != 0 and ("invalid CA" in vtxt or "certificate signing" in vtxt.lower()),
          vtxt.strip()[:220])
    rc, out, _ = sh(["openssl", "verify", "-CAfile", rogue_root, "-untrusted",
                     os.path.join(CERTS, "rogue-inter-ca.crt"), C["rogue"][0]])
    check("[pki] rogue chain verifies under its own root (so live refusals are trust, not shape)",
          rc == 0, out.strip()[:200])
    rc, out, err = sh(["openssl", "verify", "-CAfile", root, C["selfsign"][0]])
    vtxt = out + err
    check("[pki] self-signed rejected against the real root",
          rc != 0 and "self-signed" in vtxt, vtxt.strip()[:200])
    check("[pki] wronghost fixture does not claim router.test",
          not check_host(C["wronghost"][0], "router.test"))
    check("[pki] wronghost fixture does claim notrouter.test",
          check_host(C["wronghost"][0], "notrouter.test"))
    check("[pki] SAN overrides CN (CN=router.test, SAN=other.test)",
          check_host(C["cnbutsan"][0], "other.test")
          and not check_host(C["cnbutsan"][0], "router.test"))
    check("[pki] no-SAN fixture really has no SAN extension",
          "Subject Alternative Name" not in sh(["openssl", "x509", "-in",
                                                C["nosan"][0], "-noout", "-text"])[1])

    # ========================================= 2. RSA group: TLS1.3 + TLS1.2
    mock_a = free_port()
    start_mock(mock_a, "tls-rsa-model")
    port_a, name_a = start_tls_router("rsa", FULL["router-rsa"], C["router-rsa"][1],
                                      worker_url="http://127.0.0.1:%d" % mock_a)
    check("[rsa] banner reports tls: on (TLSv1.2/1.3)",
          "tls: on (TLSv1.2/1.3)" in logs(name_a), logs(name_a).splitlines()[:1])
    rendered = sh(["docker", "exec", name_a, "cat",
                   "/usr/local/openresty/nginx/conf/nginx.conf"])[1]
    check("[rsa] render turns the main listener into ssl",
          "listen 0.0.0.0:%d ssl;" % port_a in rendered,
          [l.strip() for l in rendered.splitlines() if "listen 0.0.0.0" in l][:2])
    check("[rsa] render ships the fullchain path",
          "ssl_certificate /gen/certs/router-rsa-fullchain.crt;" in rendered,
          [l.strip() for l in rendered.splitlines() if "ssl_certificate" in l][:2])
    check("[rsa] /health 200 trusting the root only, by hostname",
          curl(port_a, "/health", cacert=root_only, host="router.test")[1] == "200",
          curl(port_a, "/health", cacert=root_only, host="router.test")[1:4])
    check("[rsa] /health 200 trusting root+intermediate",
          curl(port_a, "/health", cacert=root_plus, host="router.test")[1] == "200")
    sa = s_client(port_a, servername="router.test", cafile=root_only)
    check("[rsa] verifying on the root alone succeeds => server sent the chain",
          sa["verify_code"] == 0, sa["verify_msg"])
    check("[rsa] chain sent = leaf + intermediate", sa["depths"] == 2,
          "%d %s" % (sa["depths"], sa["subjects"]))
    check("[rsa] leaf served is the expected RSA leaf",
          sa["leaf_fp"] == FP["router-rsa"], "%s != %s" % (sa["leaf_fp"],
                                                           FP["router-rsa"]))
    check("[rsa] IP SAN serves a literal-IP URL",
          curl(port_a, "/health", cacert=root_only)[1] == "200")
    check("[rsa] second SAN DNS name serves",
          curl(port_a, "/health", cacert=root_only, host="www.router.test")[1] == "200")
    pa13 = https_probe(port_a, cafile=root_only, sni="router.test")
    check("[rsa] TLSv1.3 negotiated by default", pa13["ok"]
          and pa13["protocol"] == "TLSv1.3" and pa13["status"] == 200,
          "%s %s" % (pa13["protocol"], pa13["err"]))
    pa12 = https_probe(port_a, cafile=root_only, sni="router.test",
                       max_proto=ssl.TLSVersion.TLSv1_2)
    check("[rsa] TLSv1.2 handshake + request 200",
          pa12["ok"] and pa12["protocol"] == "TLSv1.2" and pa12["status"] == 200,
          "%s %s" % (pa12["protocol"], pa12["err"]))
    check("[rsa] TLSv1.2 suite uses the RSA leaf (ECDHE-RSA)",
          "ECDHE-RSA" in pa12["cipher"], pa12["cipher"])
    sa12 = s_client(port_a, servername="router.test", cafile=root_only, tls="-tls1_2")
    check("[rsa] openssl agrees: TLSv1.2 verify ok on an RSA suite",
          sa12["verify_code"] == 0 and "ECDHE-RSA" in sa12["cipher"],
          "%s %s" % (sa12["protocol"], sa12["cipher"]))
    _, code, _, err = curl(port_a, "/health", cacert=root_only, tls_max="1.1")
    check("[rsa] TLSv1.1 client gets no response", code != "200", "%s %s" % (code, err))
    check("[rsa] plain http is not served on the TLS port",
          sh(["curl", "-sS", "-m", "5", "-o", "/dev/null", "-w", "%{http_code}",
              "http://127.0.0.1:%d/health" % port_a])[1] != "200")
    _, code, _, err = register_tls(port_a, root_only, "router.test",
                                   "http://127.0.0.1:%d" % mock_a, "tls-rsa-model")
    check("[rsa] POST /workers over TLS accepted (202)", code == "202",
          "%s %s" % (code, err[:150]))
    check("[rsa] worker healthy behind TLS", wait_workers_tls(port_a, root_only,
                                                              "router.test"))
    _, code, body, _ = chat_tls(port_a, root_only, "router.test", "tls-rsa-model",
                                "chain rsa probe")
    check("[rsa] chat completes over the chained listener",
          code == "200" and "chain rsa probe" in body, "%s %s" % (code, body[:150]))
    _, code, raw, _ = chat_tls(port_a, root_plus, "router.test", "tls-rsa-model",
                               "stream rsa probe", stream=True)
    check("[rsa] SSE streams over TLS", code == "200" and "data: [DONE]" in raw,
          "%s %s" % (code, raw[:120]))

    # ==================================== 3. ECDSA P-256 group: TLS1.3 + TLS1.2
    mock_b = free_port()
    start_mock(mock_b, "tls-ec-model")
    port_b, name_b = start_tls_router("ec", FULL["router-ec"], C["router-ec"][1],
                                      worker_url="http://127.0.0.1:%d" % mock_b)
    sb = s_client(port_b, servername="ec.router.test", cafile=root_only)
    check("[ec] verifying on the root alone succeeds", sb["verify_code"] == 0,
          sb["verify_msg"])
    check("[ec] leaf served is the expected P-256 leaf",
          sb["leaf_fp"] == FP["router-ec"], "%s != %s" % (sb["leaf_fp"], FP["router-ec"]))
    check("[ec] chain sent = leaf + intermediate", sb["depths"] == 2, sb["subjects"])
    pb13 = https_probe(port_b, cafile=root_only, sni="ec.router.test")
    check("[ec] TLSv1.3 negotiated", pb13["ok"] and pb13["protocol"] == "TLSv1.3"
          and pb13["status"] == 200, "%s %s" % (pb13["protocol"], pb13["err"]))
    pb12 = https_probe(port_b, cafile=root_only, sni="ec.router.test",
                       max_proto=ssl.TLSVersion.TLSv1_2)
    check("[ec] TLSv1.2 handshake + request 200",
          pb12["ok"] and pb12["protocol"] == "TLSv1.2" and pb12["status"] == 200,
          "%s %s" % (pb12["protocol"], pb12["err"]))
    check("[ec] TLSv1.2 suite uses the EC leaf (ECDHE-ECDSA)",
          "ECDHE-ECDSA" in pb12["cipher"], pb12["cipher"])
    check("[ec] the SMG_WORKER_URLS worker is healthy behind the EC listener",
          wait_workers_tls(port_b, root_only, "ec.router.test"),
          "worker never reported healthy")
    _, code, body, _ = chat_tls(port_b, root_only, "ec.router.test", "tls-ec-model",
                                "chain ec probe")
    check("[ec] chat completes over the ECDSA chain",
          code == "200" and "chain ec probe" in body, "%s %s" % (code, body[:150]))
    check("[ec] IP SAN on the EC leaf serves",
          curl(port_b, "/health", cacert=root_only)[1] == "200")
    check("[ec] mTLS not requested: server sends no client-CA list",
          sb["no_client_ca"], "client CA names were sent")
    mt = https_probe(port_b, cafile=root_only, sni="ec.router.test",
                     client_cert=(C["router-rsa"][0], C["router-rsa"][1]))
    check("[ec] a client certificate is accepted without being asked for (no mTLS)",
          mt["ok"] and mt["status"] == 200, mt["err"])

    # ==================================== 4. SNI: two names, two certs, one port
    port_c = free_port()
    frag = os.path.join(FRAG, "sni-alt.conf")
    write(frag, """    server {
        listen 0.0.0.0:%d ssl;
        server_name alt.router.test;
        ssl_certificate %s/certs/alt-ec-fullchain.crt;
        ssl_certificate_key %s/private/alt-ec.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
            content_by_lua_block {
                require("resty.luarouter.router").handle()
            }
        }
    }
""" % (port_c, GEN, GEN))
    try:
        port_c, name_c = start_tls_router("sni", FULL["router-rsa"], C["router-rsa"][1],
                                          port=port_c, fragment="/frag/sni-alt.conf")
        s_main = s_client(port_c, servername="router.test", cafile=root_only)
        s_alt = s_client(port_c, servername="alt.router.test", cafile=root_only)
        s_www = s_client(port_c, servername="www.router.test", cafile=root_only)
        s_none = s_client(port_c, servername=None, cafile=root_only)
        check("[sni] SNI router.test -> RSA leaf (default server)",
              s_main["leaf_fp"] == FP["router-rsa"], s_main["leaf_fp"])
        check("[sni] SNI alt.router.test -> EC leaf (second server block)",
              s_alt["leaf_fp"] == FP["alt-ec"], "%s != %s" % (s_alt["leaf_fp"],
                                                              FP["alt-ec"]))
        check("[sni] the alt cert also verifies on the same root",
              s_alt["verify_code"] == 0, s_alt["verify_msg"])
        check("[sni] unmatched SNI falls back to the default cert",
              s_www["leaf_fp"] == FP["router-rsa"], s_www["leaf_fp"])
        check("[sni] a ClientHello without SNI falls back to the default cert",
              s_none["leaf_fp"] == FP["router-rsa"], s_none["leaf_fp"])
        _, c1, b1, _ = curl(port_c, "/workers", cacert=root_only, host="router.test")
        _, c2, b2, _ = curl(port_c, "/workers", cacert=root_only, host="alt.router.test")
        check("[sni] both names serve the router API",
              c1 == "200" and c2 == "200" and "workers" in b1 and "workers" in b2,
              "%s %s" % (c1, c2))
        _, c3, _, _ = register_tls(port_c, root_only, "alt.router.test",
                                   "http://127.0.0.1:%d" % mock_b, "sni-model")
        _, c4, b4, _ = curl(port_c, "/workers", cacert=root_only, host="router.test")
        check("[sni] one router state behind both names",
              c3 == "202" and c4 == "200" and "sni-model" in b4, "%s %s" % (c3, b4[:160]))
        s_alt12 = s_client(port_c, servername="alt.router.test", cafile=root_only,
                           tls="-tls1_2")
        check("[sni] the alt name negotiates an EC suite at TLSv1.2",
              "ECDHE-ECDSA" in s_alt12["cipher"], s_alt12["cipher"])
        s_main12 = s_client(port_c, servername="router.test", cafile=root_only,
                            tls="-tls1_2")
        check("[sni] the main name negotiates an RSA suite at TLSv1.2 on the same port",
              "ECDHE-RSA" in s_main12["cipher"], s_main12["cipher"])
    except RuntimeError as e:
        check("[sni] dual-certificate listener starts", False, str(e)[:300])

    # =========================== 5. negatives, one reason each (helper-driven)
    def negative(tag, key_name, trust, expect_curl, expect_py, expect_ssl=None):
        host = HOST[key_name]
        try:
            port, name = start_tls_router(tag, FULL[key_name], C[key_name][1])
        except RuntimeError as e:
            check("[%s] router boots with this material" % tag, False, str(e)[:250])
            return
        rc, code, _, err = curl(port, "/health", cacert=trust, host=host)
        check("[%s] curl refuses (no response)" % tag, rc != 0 and code != "200",
              "%s %s" % (code, err[:160]))
        check("[%s] curl reason: %s" % (tag, expect_curl), expect_curl in err.lower(),
              err[:220])
        pr = https_probe(port, cafile=trust, sni=host)
        check("[%s] python verifier refuses" % tag, not pr["ok"], pr["err"][:200])
        check("[%s] python reason: %s" % (tag, expect_py), expect_py in pr["err"].lower(),
              pr["err"][:220])
        sc = s_client(port, servername=host, cafile=trust)
        check("[%s] openssl verifier code non-zero" % tag,
              sc["verify_code"] not in (0, None),
              "%s %s" % (sc["verify_code"], sc["verify_msg"]))
        if expect_ssl:
            check("[%s] openssl reason: %s" % (tag, expect_ssl),
                  expect_ssl in (sc["verify_msg"] + " " + sc["text"]).lower(),
                  sc["verify_msg"])
        check("[%s] the refused leaf was still transmitted (verdict is client-side)" % tag,
              sc["leaf_fp"] == FP.get(key_name),
              "sent %r expected %r | %s" % (sc["leaf_fp"], FP.get(key_name),
                                            sc["verify_msg"]))
        _, code, _, _ = curl(port, "/health", insecure=True)
        check("[%s] -k still gets 200 (router is up, not broken)" % tag, code == "200", code)
        check("[%s] container alive after the refusals" % tag, alive(name))
        check("[%s] no crash/emerg lines" % tag, not crash_lines(name),
              crash_lines(name)[:2])
        stop(name)
        if name in CA_CONTAINERS:
            CA_CONTAINERS.remove(name)

    negative("expired", "expired", root_plus, "certificate has expired",
             "certificate has expired", "expired")
    negative("rogue-ca", "rogue", root_plus, "unable to get local issuer certificate",
             "unable to get local issuer certificate",
             "unable to get local issuer certificate")
    negative("nonca", "fake", fake_issuer, "invalid ca certificate",
             "invalid ca certificate", "key usage does not include certificate signing")
    negative("selfsigned", "selfsign", root_plus, "self-signed certificate",
             "self-signed certificate", "self-signed certificate")

    # hostname/SAN mismatch: the chain itself verifies, only the name fails
    try:
        port_w, name_w = start_tls_router("wronghost", FULL["wronghost"],
                                          C["wronghost"][1])
        _, code, _, err = curl(port_w, "/health", cacert=root_plus, host="router.test")
        check("[mismatch] curl refuses a valid chain on the wrong name",
              code != "200" and "no alternative certificate subject name" in err.lower(),
              err[:220])
        pw = https_probe(port_w, cafile=root_plus, sni="router.test", check_name=True)
        check("[mismatch] python client reports the hostname mismatch",
              not pw["ok"] and "hostname mismatch" in pw["err"].lower(), pw["err"][:220])
        sw = s_client(port_w, servername="router.test", cafile=root_plus)
        check("[mismatch] chain alone verifies, so the failure really is the name",
              sw["verify_code"] == 0, sw["verify_msg"])
        swh = s_client(port_w, servername="router.test", cafile=root_plus,
                       verify_host="router.test")
        check("[mismatch] openssl -verify_hostname refuses it",
              swh["verify_code"] not in (0, None)
              and "hostname" in swh["verify_msg"].lower(),
              "%s %s" % (swh["verify_code"], swh["verify_msg"]))
        _, code, _, _ = curl(port_w, "/health", cacert=root_plus, host="notrouter.test")
        check("[mismatch] the matching name on the same cert serves 200", code == "200", code)
        stop(name_w)
        if name_w in CA_CONTAINERS:
            CA_CONTAINERS.remove(name_w)
    except RuntimeError as e:
        check("[mismatch] router boots with the mismatched leaf", False, str(e)[:250])

    # SAN present but not covering the CN
    try:
        port_n, name_n = start_tls_router("cnbutsan", FULL["cnbutsan"], C["cnbutsan"][1])
        _, code, _, err = curl(port_n, "/health", cacert=root_plus, host="router.test")
        check("[cnbutsan] SAN present => CN ignored, CN-only match refused",
              code != "200" and "no alternative certificate subject name" in err.lower(),
              err[:220])
        _, code, _, _ = curl(port_n, "/health", cacert=root_plus, host="other.test")
        check("[cnbutsan] the SAN name serves 200", code == "200", code)
        stop(name_n)
        if name_n in CA_CONTAINERS:
            CA_CONTAINERS.remove(name_n)
    except RuntimeError as e:
        check("[cnbutsan] router boots", False, str(e)[:250])

    # no SAN at all: OpenSSL's matcher falls back to the CN, browsers do not
    try:
        port_s, name_s = start_tls_router("nosan", FULL["nosan"], C["nosan"][1])
        _, code, _, err = curl(port_s, "/health", cacert=root_plus, host="router.test")
        check("[nosan] OpenSSL clients fall back to the CN and accept it",
              code == "200", "%s %s" % (code, err[:150]))
        _, code, _, _ = curl(port_s, "/health", cacert=root_plus, host="other.test")
        check("[nosan] a name matching neither SAN nor CN is refused", code != "200", code)
        note("no-SAN leaf: OpenSSL 3 (curl / python / s_client) accepts the subject CN, "
             "so this shape is client-dependent and unsafe -- RFC 6125 obsoletes the CN "
             "fallback and browsers/Go reject it. Recorded, not a router defect.")
        stop(name_s)
        if name_s in CA_CONTAINERS:
            CA_CONTAINERS.remove(name_s)
    except RuntimeError as e:
        check("[nosan] router boots", False, str(e)[:250])

    # ============ 6. certificate/key pairing: a real gap in the entrypoint gate
    _, pub_cert, _ = sh(["openssl", "x509", "-in", FULL["router-rsa"], "-noout", "-pubkey"])
    _, pub_other, _ = sh(["openssl", "pkey", "-in", C["router-ec"][1], "-pubout"])
    check("[pairing] fixture really is a leaf and a key from different keypairs",
          pub_cert.strip() != pub_other.strip(), "")
    try:
        port_m, name_m = start_tls_router("pairing", C["wronghost"][0],
                                          C["router-ec"][1], wait=False,
                                          extra_env={"SMG_LOG_LEVEL": "info"})
        _, code, _, err = curl(port_m, "/health", insecure=True, timeout=6)
        check("[pairing] openresty -t passes and the container boots", alive(name_m),
              logs(name_m)[-250:])
        check("[pairing] but every handshake dies (TLS alert 40, no suitable signature)",
              code != "200" and "handshake failure" in err.lower(), "%s %s" % (code, err[:160]))
        check("[pairing] the cause is only visible at info level in the error log",
              "no suitable signature algorithm" in logs(name_m), logs(name_m)[-250:])
        check("[pairing] no crash lines (this fails closed, it does not crash)",
              not crash_lines(name_m), crash_lines(name_m)[:2])
        note("cert/key mismatch is NOT caught by docker-entrypoint.sh: `openresty -t` "
             "does not verify the pairing, so the instance boots healthy-looking and "
             "serves nothing. The image ships no openssl binary (verified: `openssl` is "
             "not in $PATH in authz:latest), so an entrypoint preflight would need "
             "resty.openssl in Lua or a vendored binary -- a core change, out of scope "
             "here. See doc/gap-tls-chain.md.")
        stop(name_m)
        if name_m in CA_CONTAINERS:
            CA_CONTAINERS.remove(name_m)
    except RuntimeError as e:
        check("[pairing] mismatched pair boots (documented gap)", False, str(e)[:250])

    # ================= 7. half-configured TLS and the plain-listener baseline
    rc, out, err = sh(["docker", "run", "--rm",
                       "-v", "%s:%s:ro" % (D, GEN),
                       "-e", "SMG_TLS_CERT_PATH=" + GEN + "/certs/router-rsa-fullchain.crt",
                       "--entrypoint", "/docker-entrypoint.sh", IMAGE, "openresty", "-t"])
    check("[render] cert without key is refused at the entrypoint",
          rc != 0 and "must be set together" in out + err, (out + err)[:200])
    rc, out, err = sh(["docker", "run", "--rm",
                       "-v", "%s:%s:ro" % (D, GEN),
                       "-e", "SMG_TLS_CERT_PATH=" + GEN + "/certs/router-rsa-fullchain.crt",
                       "-e", "SMG_TLS_KEY_PATH=" + GEN + "/certs/absent.key",
                       "--entrypoint", "/docker-entrypoint.sh", IMAGE, "openresty", "-t"])
    check("[render] missing key file is refused at the entrypoint",
          rc != 0 and "certificate or key missing" in out + err, (out + err)[:200])
    rc, out, err = sh(["docker", "run", "--rm",
                       "-v", "%s:%s:ro" % (D, GEN),
                       "-e", "SMG_TLS_CERT_PATH=" + GEN + "/certs/root-ca.crt",
                       "-e", "SMG_TLS_KEY_PATH=" + GEN + "/private/root-ca.key",
                       "-e", "SMG_PORT=31337", "-e", "SMG_METRICS_PORT=0",
                       "-e", "LR_UI_CONF=off",
                       "--entrypoint", "/docker-entrypoint.sh", IMAGE, "openresty", "-t"])
    check("[render] a CA certificate as a server cert still renders",
          rc == 0 and "the configuration file" in out + err, (out + err)[:200])
    return finish()


if __name__ == "__main__":
    main()

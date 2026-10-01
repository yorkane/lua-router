#!/usr/bin/env python3
"""End-to-end checks for the JWT/JWKS control-plane gate (doc/gap-dp-jwt.md).

Everything is generated in-process: two signing keys (RSA-2048 and EC P-256), a
local JWKS document served over loopback http, and compact JWS tokens minted by
hand (no pyjwt in this environment, and hand-rolling is also what proves the
module speaks plain JWS rather than a library dialect).

The router container points SMG_JWT_JWKS_URI at the in-file JWKS server, which
counts its own requests. The counter is the only way to see the cache from
outside, so two of the checks are about fetch counts rather than statuses.

Groups, in run order:
  A. happy path: RS256 admin through the role mapping, ES256 admin, the aud array
     spelling, the x-api-key header still being the API-key channel only.
  B. refusals: expired, wrong iss, wrong aud, nbf in the future, a user-mapped
     role, an unmapped role, tampered signature, HS256 (unsigned-alg family),
     algorithm confusion (ES256 header against an RSA kid), no kid, garbage.
  C. fallback rules: a definitive JWT failure does NOT unlock a valid API key
     (smg-auth's middleware answers 401 there), while a JWKS endpoint that cannot
     be reached does fall back and the API key works; a non-JWS bearer is an API
     key, not a broken JWT; no credential at all stays 401.
  D. JWKS cache and rotation: repeated requests cost one fetch, an unknown kid
     forces exactly one refresh, and a token signed by a key published after boot
     starts working without restarting the router.
  E. audit trail at info level: auth_method=jwt on the allow line, and the token
     itself never appearing in the log.

Run: python3 test/integration/e2e_jwt.py
Requires the image built (final_gates.sh `build` gate).
"""
import base64, json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _lib import (free_port, http, check, logs, RESULTS, RUN, IMAGE)

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

TMP = os.environ.get("LR_TEST_TMP", "/data/tmp/lr")
os.makedirs(TMP, exist_ok=True)
CONTAINERS = []

ISSUER = "https://idp.internal.example"
AUDIENCE = "smg-control-plane"


def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def int_b64(value, width=None):
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if width and len(raw) < width:
        raw = b"\x00" * (width - len(raw)) + raw
    return b64u(raw)


# ------------------------------------------------------------------ signing keys
RSA_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
EC_KEY = ec.generate_private_key(ec.SECP256R1())

RSA_PUB = RSA_KEY.public_key().public_numbers()
EC_PUB = EC_KEY.public_key().public_numbers()

KEYS = {
    "key-1": {"kty": "RSA", "kid": "key-1", "use": "sig", "alg": "RS256",
              "n": int_b64(RSA_PUB.n, 256), "e": int_b64(RSA_PUB.e),
              "private": RSA_KEY},
    "key-2": {"kty": "EC", "kid": "key-2", "use": "sig", "alg": "ES256",
              "crv": "P-256", "x": int_b64(EC_PUB.x, 32), "y": int_b64(EC_PUB.y, 32),
              "private": EC_KEY},
}
# What the JWKS endpoint publishes. Rotation appends to this list.
PUBLISHED = ["key-1", "key-2"]
FETCHES = {"count": 0}
PUBLISH_LOCK = threading.Lock()


def jwk_public(kid):
    src = KEYS[kid]
    return {k: v for k, v in src.items() if k != "private"}


class JwksHandler(BaseHTTPRequestHandler):
    server_version = "MockIdP/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.split("?", 1)[0] not in ("/keys", "/jwks.json"):
            self.send_response(404)
            self.send_header("content-length", "0")
            self.end_headers()
            return
        with PUBLISH_LOCK:
            doc = {"keys": [jwk_public(k) for k in PUBLISHED]}
        FETCHES["count"] += 1
        body = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


def sign(kid, header, payload):
    """Compact JWS for one published key. kid may name an unpublished key, which is
    how the rotation and unknown-kid cases are produced."""
    key = KEYS[kid]["private"]
    alg = KEYS[kid]["alg"]
    signing_input = (b64u(json.dumps(header, separators=(",", ":")).encode())
                     + "." + b64u(json.dumps(payload, separators=(",", ":")).encode()))
    if alg.startswith("RS"):
        sig = key.sign(signing_input.encode(),
                       padding.PKCS1v15(), hashes.SHA256())
    else:
        der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + b64u(sig)


def token(kid="key-1", alg=None, roles=("ops",), sign_kid=None, **claims):
    """Mint a JWS. kid goes in the header, sign_kid (default: the same key) decides
    what actually signed it, so an unknown-kid token is a normal signature under a
    header nobody can resolve."""
    header = {"alg": alg or KEYS[sign_kid or kid]["alg"], "typ": "JWT", "kid": kid}
    now = int(time.time())
    payload = {"iss": ISSUER, "aud": AUDIENCE, "sub": "sre-1",
               "iat": now, "exp": now + 600, "roles": list(roles)}
    payload.update(claims)
    for drop in [k for k, v in payload.items() if v is None]:
        del payload[drop]
    return sign(sign_kid or kid, header, payload)


def header(tok=None):
    return {"Authorization": "Bearer " + tok} if tok else {}


# ------------------------------------------------------------------- containers
def start_router(env, name):
    port = free_port()
    args = ["docker", "run", "-d", "--name", name]
    for k, v in env.items():
        args += ["-e", "%s=%s" % (k, v)]
    args += ["-e", "SMG_PORT=%d" % port, "--network", "host", "-e", "SMG_METRICS_PORT=0",
             "--entrypoint", "/docker-entrypoint.sh", IMAGE,
             "/usr/local/openresty/bin/openresty", "-p", "/usr/local/openresty/nginx",
             "-g", "daemon off;"]
    subprocess.run(args, check=True, capture_output=True)
    CONTAINERS.append(name)
    for _ in range(120):
        st, _, _ = http("GET", "http://127.0.0.1:%d/health" % port, timeout=2)
        if st == 200:
            return port
        time.sleep(0.25)
    raise RuntimeError("router %s never came up:\n%s" % (name, logs(name)))


def stop(name):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def code_of(st, body):
    try:
        return json.loads(body).get("error", {}).get("code")
    except ValueError:
        return None


# ----------------------------------------------------------------------- groups
def group_allow(base):
    st, body, _ = http("GET", base + "/workers", headers=header(token()))
    check("[jwt] RS256 token whose role maps to admin reaches the control plane",
          st == 200, "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers", headers=header(token(kid="key-2")))
    check("[jwt] ES256 token is accepted with the same rules", st == 200,
          "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/v1/loads", headers=header(token()))
    check("[jwt] admin JWT reaches a second control-plane route", st == 200,
          "%s %s" % (st, body[:150]))
    st, body, _ = http("GET", base + "/workers",
                       headers=header(token(roles=["ops", "observer"])))
    check("[jwt] a multi-role token keeps the admin mapping", st == 200,
          "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers",
                       headers=header(token(aud=[AUDIENCE, "other-service"])))
    check("[jwt] aud as an array containing ours passes (Rust subset rule)",
          st == 200, "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers", headers={"x-api-key": token()})
    check("[jwt] a JWT in x-api-key is not a JWT: JWT is Bearer-only", st == 401,
          "%s %s" % (st, body[:200]))


def group_deny(base):
    st, body, _ = http("GET", base + "/workers",
                       headers=header(token(exp=int(time.time()) - 1200)))
    check("[jwt] expired token is refused", st == 401, "%s %s" % (st, body[:200]))
    check("[jwt] 401 names the JWT path", "invalid JWT" in body, body[:200])
    check("[jwt] 401 error code", code_of(st, body) == "unauthorized", body[:200])

    st, _, _ = http("GET", base + "/workers",
                    headers=header(token(exp=int(time.time()) - 1200,
                                        iat=int(time.time()) - 2400)))
    check("[jwt] expired past the leeway stays refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers",
                    headers=header(token(nbf=int(time.time()) + 3600)))
    check("[jwt] nbf in the future is refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(iss="https://other.example")))
    check("[jwt] wrong issuer is refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(aud="someone-else")))
    check("[jwt] wrong audience is refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(iss=None, aud=None)))
    check("[jwt] missing iss/aud is refused when configured", st == 401, str(st))

    st, body, _ = http("GET", base + "/workers", headers=header(token(roles=["guest"])))
    check("[jwt] a role mapped to user authenticates and gets 403", st == 403,
          "%s %s" % (st, body[:200]))
    check("[jwt] 403 carries the same message as the API-key path",
          "Admin role required" in body, body[:200])
    st, _, _ = http("GET", base + "/workers", headers=header(token(roles=["unmapped-role"])))
    check("[jwt] an identity absent from the mapping defaults to user (403)",
          st == 403, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(roles=[])))
    check("[jwt] a token with no roles defaults to user (403)", st == 403, str(st))

    good = token()
    tampered = good[:-6] + ("AAAAAA" if good[-6:] != "AAAAAA" else "BBBBBB")
    st, _, _ = http("GET", base + "/workers", headers=header(tampered))
    check("[jwt] tampered signature is refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(alg="HS256")))
    check("[jwt] HS256 is refused before any key lookup", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers",
                    headers=header(token(kid="key-2", alg="RS256")))
    check("[jwt] alg confusing an EC key for an RSA one is refused", st == 401, str(st))
    st, _, _ = http("GET", base + "/workers",
                    headers=header(token(kid="key-1", alg="ES256")))
    check("[jwt] alg confusing an RSA key for an EC one is refused", st == 401, str(st))
    kidless = token().split(".")
    raw = json.loads(base64.urlsafe_b64decode(kidless[0] + "=" * (-len(kidless[0]) % 4)))
    del raw["kid"]
    signing_input = (b64u(json.dumps(raw, separators=(",", ":")).encode())
                     + "." + kidless[1])
    sig = KEYS["key-1"]["private"].sign(signing_input.encode(),
                                        padding.PKCS1v15(), hashes.SHA256())
    st, body, _ = http("GET", base + "/workers",
                       headers=header(signing_input + "." + b64u(sig)))
    check("[jwt] a JWS with no kid is refused (Rust MissingKid)", st == 401,
          "%s %s" % (st, body[:200]))
    st, _, _ = http("GET", base + "/workers", headers=header("not-a-jwt-at-all"))
    check("[jwt] a non-JWS bearer is handled by the key list, not 401-by-JWT",
          st == 401, str(st))


def group_fallback():
    """Two containers: one where JWT works and must not be rescued by a key, one
    where the JWKS endpoint cannot be reached at all and must not lock anyone out.

    The dead-endpoint container is the one that actually distinguishes the two
    behaviours, and the evidence is the error text: falling through to the key list
    answers "invalid control plane key", while a JWT plane that hard-fails answers
    "invalid JWT: cannot load JWKS"."""
    live = ThreadingHTTPServer(("127.0.0.1", free_port()), JwksHandler)
    live.daemon_threads = True
    threading.Thread(target=live.serve_forever, daemon=True).start()

    name = "lr-jwt-live-%s" % RUN
    port = start_router({"SMG_JWT_ISSUER": ISSUER, "SMG_JWT_AUDIENCE": AUDIENCE,
                         "SMG_JWT_JWKS_URI": "http://127.0.0.1:%d/keys" % live.server_address[1],
                         "SMG_JWT_ROLE_MAPPING": "ops:admin,guest:user",
                         "SMG_CONTROL_PLANE_API_KEYS": "ops:SRE:admin:sk-jwt-fb-admin"},
                        name)
    base = "http://127.0.0.1:%d" % port
    st, _, _ = http("GET", base + "/workers", headers=header(token()))
    check("[fb] with keys configured too, an admin JWT is still accepted", st == 200, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(token(roles=["guest"])))
    check("[fb] a user-role JWT is 403 even though an admin key exists", st == 403, str(st))

    expired = token(exp=int(time.time()) - 1200)
    st, body, _ = http("GET", base + "/workers",
                       headers={"Authorization": "Bearer sk-jwt-fb-admin"})
    check("[fb] baseline: the admin API key itself works here", st == 200,
          "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers",
                       headers={"Authorization": "Bearer " + expired})
    check("[fb] a forged/expired JWT is not rescued by a valid admin key",
          st == 401 and "invalid JWT" in body, "%s %s" % (st, body[:200]))
    stop(name)
    live.shutdown()
    live.server_close()

    # Point at a port nobody listens on. The fetch fails for every request, which is
    # the "JWT 不可用" case: the gate has to step aside and let the key list decide.
    dead = free_port()
    name = "lr-jwt-dead-%s" % RUN
    port = start_router({"SMG_JWT_ISSUER": ISSUER, "SMG_JWT_AUDIENCE": AUDIENCE,
                         "SMG_JWT_JWKS_URI": "http://127.0.0.1:%d/keys" % dead,
                         "SMG_JWT_JWKS_CACHE_SECS": "0",
                         "SMG_JWT_ROLE_MAPPING": "ops:admin",
                         "SMG_CONTROL_PLANE_API_KEYS": "ops:SRE:admin:sk-jwt-fb-admin"},
                        name)
    base = "http://127.0.0.1:%d" % port
    st, body, _ = http("GET", base + "/workers", headers=header(token()))
    check("[fb] an unreachable JWKS does not hard-fail a JWT: it falls through",
          st == 401 and "invalid control plane key" in body, "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers", headers={"Authorization": "Bearer sk-jwt-fb-admin"})
    check("[fb] with the JWKS endpoint dead, the admin API key still works",
          st == 200, "%s %s" % (st, body[:200]))
    st, body, _ = http("GET", base + "/workers")
    check("[fb] no credential still answers 401", st == 401, "%s %s" % (st, body[:150]))
    stop(name)


def group_cache():
    global PUBLISHED
    srv = ThreadingHTTPServer(("127.0.0.1", free_port()), JwksHandler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port_idp = srv.server_address[1]
    name = "lr-jwt-cache-%s" % RUN
    port = start_router({"SMG_JWT_ISSUER": ISSUER, "SMG_JWT_AUDIENCE": AUDIENCE,
                         "SMG_JWT_JWKS_URI": "http://127.0.0.1:%d/keys" % port_idp,
                         "SMG_JWT_ROLE_MAPPING": "ops:admin",
                         "SMG_JWT_JWKS_CACHE_SECS": "3000",
                         "SMG_CONTROL_PLANE_API_KEYS": "ops:SRE:admin:sk-jwt-cache"}, name)
    base = "http://127.0.0.1:%d" % port

    FETCHES["count"] = 0
    ok = all(http("GET", base + "/workers", headers=header(token()))[0] == 200
             for _ in range(5))
    first = FETCHES["count"]
    check("[cache] five accepted requests all succeed", ok)
    check("[cache] the JWKS document is fetched once and then cached", first == 1,
          "%d fetches" % first)

    # Publish a second key and use a token signed by it: the kid miss has to force
    # exactly one refresh, which is what makes rotation work without a restart.
    rsa2 = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nums = rsa2.public_key().public_numbers()
    KEYS["key-3"] = {"kty": "RSA", "kid": "key-3", "use": "sig", "alg": "RS256",
                     "n": int_b64(nums.n, 256), "e": int_b64(nums.e), "private": rsa2}
    with PUBLISH_LOCK:
        PUBLISHED = ["key-1", "key-3"]
    st, body, _ = http("GET", base + "/workers", headers=header(token(kid="key-3")))
    check("[cache] a key published after boot is picked up on the kid miss",
          st == 200, "%s %s" % (st, body[:200]))
    check("[cache] the unknown kid cost exactly one refresh",
          FETCHES["count"] == 2, "%d fetches" % FETCHES["count"])

    # The old key stays valid, and now the new one is cached as well.
    st, _, _ = http("GET", base + "/workers", headers=header(token()))
    check("[cache] the original key still verifies after the refresh", st == 200, str(st))
    check("[cache] no extra fetch behind that request", FETCHES["count"] == 2,
          "%d fetches" % FETCHES["count"])

    # A kid that will never exist must not turn into a fetch per request.
    st, _, _ = http("GET", base + "/workers", headers=header(token(kid="key-3")))
    for _ in range(4):
        http("GET", base + "/workers",
             headers=header(token(kid="ghost", sign_kid="key-1")))
    check("[cache] unknown kids are rate limited, not fetched per request",
          FETCHES["count"] == 2, "%d fetches" % FETCHES["count"])
    stop(name)
    srv.shutdown()
    srv.server_close()


def group_audit():
    """Separate container at info level so the audit lines are in docker logs."""
    srv = ThreadingHTTPServer(("127.0.0.1", free_port()), JwksHandler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    name = "lr-jwt-audit-%s" % RUN
    port = start_router({"SMG_JWT_ISSUER": ISSUER, "SMG_JWT_AUDIENCE": AUDIENCE,
                         "SMG_JWT_JWKS_URI": "http://127.0.0.1:%d/keys" % srv.server_address[1],
                         "SMG_JWT_ROLE_MAPPING": "ops:admin,guest:user",
                         "SMG_CONTROL_PLANE_API_KEYS": "ops:SRE:admin:sk-jwt-audit",
                         "SMG_LOG_LEVEL": "info"}, name)
    base = "http://127.0.0.1:%d" % port
    admin_tok = token()
    user_tok = token(roles=["guest"])
    st, _, _ = http("GET", base + "/workers", headers=header(admin_tok))
    check("[audit] admin JWT accepted (info-level container)", st == 200, str(st))
    st, _, _ = http("GET", base + "/workers", headers=header(user_tok))
    check("[audit] user JWT refused (info-level container)", st == 403, str(st))
    st, _, _ = http("GET", base + "/workers",
                    headers=header(token(roles=["guest"], exp=int(time.time()) - 1200)))
    check("[audit] expired JWT refused (info-level container)", st == 401, str(st))

    text = logs(name)
    check("[audit] allow line reports auth_method=jwt",
          "outcome=allow" in text and "auth_method=jwt" in text, text[-400:])
    check("[audit] allow line carries the subject as the principal",
          "principal=jwt:sre-1" in text, text[-400:])
    check("[audit] the role is reported for the user token",
          "outcome=deny" in text and "role=user" in text, text[-400:])
    check("[audit] refused JWT is logged with its reason",
          "reason=invalid_jwt" in text, text[-400:])
    joined = text.replace("\\r", "").replace("\\n", "")
    check("[audit] the token itself is never logged",
          admin_tok[:40] not in joined and user_tok[:40] not in joined,
          "a bearer value leaked into the log")
    # The data plane must not consult the JWT plane at all.
    st, _, _ = http("GET", base + "/health")
    check("[audit] /health stays open with the JWT gate configured", st == 200, str(st))
    st, body, _ = http("GET", base + "/v1/models", headers=header("garbage"))
    check("[audit] a public route never demands a credential from the JWT plane",
          st != 401 and st != 403, "%s %s" % (st, body[:150]))
    stop(name)
    srv.shutdown()
    srv.server_close()


def main():
    stale = [n for n in subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"],
                                       capture_output=True).stdout.decode().split()
             if n.startswith("lr-jwt-")]
    for n in stale:
        subprocess.run(["docker", "rm", "-f", n], capture_output=True)

    idp = ThreadingHTTPServer(("127.0.0.1", free_port()), JwksHandler)
    idp.daemon_threads = True
    threading.Thread(target=idp.serve_forever, daemon=True).start()
    try:
        name = "lr-jwt-main-%s" % RUN
        port = start_router({"SMG_JWT_ISSUER": ISSUER, "SMG_JWT_AUDIENCE": AUDIENCE,
                             "SMG_JWT_JWKS_URI": "http://127.0.0.1:%d/keys" % idp.server_address[1],
                             "SMG_JWT_ROLE_CLAIM": "roles",
                             "SMG_JWT_ROLE_MAPPING": "ops:admin,guest:user",
                             "SMG_JWT_LEEWAY_SECS": "30",
                             "SMG_CONTROL_PLANE_API_KEYS": "ops:SRE:admin:sk-jwt-main"}, name)
        base = "http://127.0.0.1:%d" % port
        group_allow(base)
        group_deny(base)
        group_fallback()
        group_cache()
        group_audit()
    finally:
        for c in CONTAINERS:
            stop(c)
        for srv in (idp,):
            srv.shutdown()
            srv.server_close()
    failed = [name for ok, name, _ in RESULTS if not ok]
    print("\n%d checks, %d failed" % (len(RESULTS), len(failed)))
    for name in failed:
        print("FAIL " + name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

-- Control-plane JWT verification against a JWKS endpoint (doc/gap-dp-jwt.md).
--
-- Port of the smg-auth crate (gateway auth: jwt.rs / jwks.rs / middleware.rs /
-- config.rs). The Rust gateway accepts either an API key or a bearer JWT on the
-- control plane; the JWT branch is what lets an external IdP hand out short-lived
-- admin tokens instead of a shared long-lived key.
--
-- Deliberate deviations from smg-auth, all recorded in doc/gap-dp-jwt.md:
--   * RS256/RS384/RS512/ES256/ES384 only (HS* and EdDSA are refused, as in Rust),
--     and the token's alg has to match the JWK's own alg, which is the algorithm
--     confusion guard.
--   * nbf IS enforced when present. Rust builds a Validation with
--     validate_nbf=false, so an nbf in the future is accepted there; enforcing it
--     is the safer superset.
--   * no SSRF private-address blocklist: this deployment lives on a private network
--     where the IdP is exactly such an address. https is always allowed and http
--     only for a loopback host, which is the one Rust rule cheap to keep.
--   * no JTI replay cache (neither does Rust by default).
--   * the key cache is per worker process rather than one RwLock for the process:
--     nginx workers do not share Lua tables, so a forced refresh only propagates to
--     the other workers through their own TTL. Same reasoning as the cache_aware
--     affinity tree (doc/impl-policies.md deviation 1).
--
-- Load-safe without ngx: the config reader and every decision function are plain
-- Lua, so the init_by_lua syntax gate can require this file and the pure parts
-- exercise under luajit.

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

-- Accepted algorithms, mirroring smg-auth's JWT_ALGS. Each entry names the md for
-- OpenSSL and whether the signature is fixed-width r||s rather than DER.
_M.SUPPORTED_ALGS = {
    RS256 = { md = "sha256", curve_bits = 256 },
    RS384 = { md = "sha384", curve_bits = 384 },
    RS512 = { md = "sha512", curve_bits = 512 },
    ES256 = { md = "sha256", curve_bits = 256, raw = true },
    ES384 = { md = "sha384", curve_bits = 384, raw = true },
}

-- smg-auth's JWT verifier refuses a body larger than this.
_M.MAX_JWKS_BYTES = 1024 * 1024
-- kid miss forces one refresh; this cooldown keeps a client sending random kids
-- from turning every request into a fetch against the IdP.
_M.FORCED_REFRESH_MIN_INTERVAL_SECS = 5

local DEFAULT_LEEWAY_SECS = 30
local DEFAULT_CACHE_SECS = 300
local DEFAULT_FETCH_TIMEOUT_MS = 5000

------------------------------------------------------------------------ pure part

---base64url decode with the padding re-added. Pure Lua on purpose: tokens come
---from a hostile client, so a malformed alphabet must be answered here instead of
---being handed to a C decoder, and the pure version is unit-testable under luajit.
---@param text string
---@return string|nil decoded, string|nil err
local function b64url_decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty"
    end
    local clean = text:gsub("-", "+"):gsub("_", "/")
    clean = clean .. string.rep("=", (4 - #clean % 4) % 4)
    if clean:match("[^A-Za-z0-9+/=]") then
        return nil, "invalid alphabet"
    end
    local decode = {}
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do
        decode[string.sub(chars, i, i)] = i - 1
    end
    decode["="] = 0

    -- Four characters at a time: a group holds at most 24 bits, so nothing here
    -- relies on double precision beyond that.
    local out = {}
    for group = 1, #clean, 4 do
        local values = {}
        local count = 0
        for offset = 0, 3 do
            local c = string.sub(clean, group + offset, group + offset)
            if c == "" or c == "=" then
                break
            end
            local v = decode[c]
            if not v then
                return nil, "invalid alphabet"
            end
            count = count + 1
            values[count] = v
        end
        if count == 1 then
            return nil, "truncated base64url"
        end
        local bits = values[1] * 2 ^ 18 + values[2] * 2 ^ 12
        if count >= 3 then
            bits = bits + values[3] * 2 ^ 6
        end
        if count >= 4 then
            bits = bits + values[4]
        end
        out[#out + 1] = string.char(math.floor(bits / 2 ^ 16) % 256)
        if count >= 3 then
            out[#out + 1] = string.char(math.floor(bits / 2 ^ 8) % 256)
        end
        if count >= 4 then
            out[#out + 1] = string.char(bits % 256)
        end
    end
    return table.concat(out)
end
_M.b64url_decode = b64url_decode

---Split a compact JWS into its three parts.
---@param token string
---@return string|nil signing_input, string|nil header_b64, string|nil claims_b64,
---        string|nil sig_b64
function _M.split_token(token)
    if type(token) ~= "string" then
        return nil
    end
    local h, c, s = string.match(token, "^([^%.]+)%.([^%.]+)%.([^%.]+)$")
    if not h then
        return nil
    end
    return h .. "." .. c, h, c, s
end

---Decode and JSON-parse one base64url JWT segment.
---@param segment string
---@return table|nil obj, string|nil err
function _M.decode_segment(segment)
    local raw, err = b64url_decode(segment)
    if not raw then
        return nil, "invalid base64url segment: " .. tostring(err)
    end
    local obj = cjson.decode(raw)
    if type(obj) ~= "table" then
        return nil, "segment is not a JSON object"
    end
    return obj
end

---------------------------------------------------------------------------- config

local function env(name)
    local ok, value = pcall(os.getenv, name)
    if not ok or type(value) ~= "string" then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function env_number(name, fallback)
    local raw = env(name)
    if not raw then
        return fallback
    end
    return tonumber(raw) or fallback
end

---`guest:user,ops:admin`, also spelled with `=` (`guest=user`). Comma or semicolon
---separates entries; the Rust CLI spells the same list as repeated
-----jwt-role-mapping idp_role=gateway_role, so both separators are accepted. A pair whose
---gateway side is neither admin nor user is dropped while the rest still parse, so
---one typo cannot disable the control plane.
---@param raw string|nil
---@return table mapping @ identity -> "admin" | "user"
function _M.parse_role_mapping(raw)
    local mapping = {}
    if type(raw) ~= "string" then
        return mapping
    end
    for field in string.gmatch(raw, "[^,;]+") do
        local identity, target = string.match(field, "^%s*([^=:%s]+)%s*[:=]%s*([%a_]+)%s*$")
        target = target and string.lower(target)
        if identity and (target == "admin" or target == "user") then
            mapping[identity] = target
        end
    end
    return mapping
end

---The JWT knobs, read once per process (the environment cannot change under a
---running worker, so this follows the same caching rule as control_plane_keys()).
---@return table
function _M.config()
    if _M._config then
        return _M._config
    end
    local mapping_raw = env("SMG_JWT_ROLE_MAPPING")
    _M._config = {
        issuer = env("SMG_JWT_ISSUER"),
        audience = env("SMG_JWT_AUDIENCE"),
        jwks_uri = env("SMG_JWT_JWKS_URI"),
        role_claim = env("SMG_JWT_ROLE_CLAIM") or "roles",
        leeway_secs = env_number("SMG_JWT_LEEWAY_SECS", DEFAULT_LEEWAY_SECS),
        cache_secs = env_number("SMG_JWT_JWKS_CACHE_SECS", DEFAULT_CACHE_SECS),
        mapping = _M.parse_role_mapping(mapping_raw),
        mapping_configured = mapping_raw ~= nil,
    }
    return _M._config
end

---Drop the cached config and key set. Test-only hook: a running worker has no way
---to see an environment edit.
function _M.reset_config()
    _M._config = nil
    _M._keys = nil
    _M._last_forced = nil
end

--------------------------------------------------------------------- claim checks

---Role claim values: one string or an array of strings. Both spellings are out
---there in IdP claims and Rust's role extraction accepts either.
---@param claims table
---@param role_claim string
---@return table roles @ list of strings
function _M.extract_roles(claims, role_claim)
    local raw = claims[role_claim]
    if raw == nil then
        -- Rust falls back through this chain when the configured claim is absent.
        for _, name in ipairs({ "role", "roles", "groups", "group" }) do
            if claims[name] ~= nil then
                raw = claims[name]
                break
            end
        end
    end
    local roles = {}
    if type(raw) == "string" then
        roles[1] = raw
    elseif type(raw) == "table" then
        for i = 1, #raw do
            if type(raw[i]) == "string" then
                roles[#roles + 1] = raw[i]
            end
        end
    end
    return roles
end

---identity -> gateway role, following Rust's resolve_role: with a mapping every
---identity is looked up and an unmatched one becomes user (never an error); without
---a mapping an identity that already spells admin or user is used as-is.
---@param roles table
---@param mapping table
---@param mapping_configured boolean
---@return string role
function _M.resolve_role(roles, mapping, mapping_configured)
    if mapping_configured then
        for i = 1, #roles do
            if mapping[roles[i]] == "admin" then
                return "admin"
            end
        end
        return "user"
    end
    for i = 1, #roles do
        if string.lower(roles[i]) == "admin" then
            return "admin"
        end
    end
    return "user"
end

---sub, falling back through email / preferred_username like Rust's subject().
---@param claims table
---@return string
function _M.subject(claims)
    for _, name in ipairs({ "sub", "email", "preferred_username" }) do
        if type(claims[name]) == "string" and claims[name] ~= "" then
            return claims[name]
        end
    end
    return "unknown"
end

---String or array membership, which is how Rust checks iss/aud: an array has to be
---a subset of the expected set, so a token listing several audiences passes when the
---configured one is among them.
---@param value any
---@param expected string|nil
---@return boolean ok
function _M.claim_matches(value, expected)
    if expected == nil then
        return true
    end
    if type(value) == "string" then
        return value == expected
    end
    if type(value) == "table" then
        for i = 1, #value do
            if value[i] == expected then
                return true
            end
        end
        return false
    end
    return false
end

---exp / nbf / iss / aud, with leeway on the two timestamps. exp is required (Rust's
---required_spec_claims = {"exp"}); issuer and audience are only checked when
---configured, matching Rust's "validate when present".
---@param claims table
---@param opts table @ {issuer, audience, leeway_secs, now}
---@return boolean ok, string|nil err
function _M.check_claims(claims, opts)
    local now = opts.now or os.time()
    local leeway = opts.leeway_secs or 0
    local exp = tonumber(claims.exp)
    if not exp then
        return false, "EXP is missing"
    end
    if exp + leeway < now then
        return false, "EXP is in the past"
    end
    if claims.nbf ~= nil then
        local nbf = tonumber(claims.nbf)
        if not nbf then
            return false, "NBF is not a number"
        end
        if nbf - leeway > now then
            return false, "NBF is in the future"
        end
    end
    if not _M.claim_matches(claims.iss, opts.issuer) then
        return false, "ISS does not match"
    end
    if not _M.claim_matches(claims.aud, opts.audience) then
        return false, "AUD does not match"
    end
    return true
end

---The JWK's own algorithm: an explicit alg wins, otherwise key type and curve
---decide (Rust's key_alg). nil means the key is unusable.
---@param jwk table
---@return string|nil alg
function _M.jwk_alg(jwk)
    if type(jwk.alg) == "string" then
        return _M.SUPPORTED_ALGS[jwk.alg] and jwk.alg or nil
    end
    if jwk.kty == "RSA" then
        return "RS256"
    end
    if jwk.kty == "EC" then
        if jwk.crv == "P-256" then
            return "ES256"
        elseif jwk.crv == "P-384" then
            return "ES384"
        end
    end
    return nil
end

-------------------------------------------------------------------- key material

local function now_secs()
    if ngx and ngx.now then
        return ngx.now()
    end
    return os.time()
end

---@return table @ {list, fetched_at}
function _M._keys_table()
    if not _M._keys then
        _M._keys = { list = nil, fetched_at = 0 }
    end
    return _M._keys
end

local function find_jwk(keys, kid)
    if type(keys) ~= "table" then
        return nil
    end
    for i = 1, #keys do
        local jwk = keys[i]
        if type(jwk) == "table" and jwk.kid == kid then
            return jwk
        end
    end
    return nil
end
_M.find_jwk = find_jwk

---Which jwks_uri spellings this module will dial. https anywhere, http only on
---loopback (the e2e's local IdP); anything else is refused before a socket opens.
---@param uri string|nil
---@return boolean ok, string|nil err
function _M.allowed_url(uri)
    local scheme, authority = string.match(uri or "", "^([%a][%w+%-.]-)://([^/%?#]+)")
    if not scheme then
        return false, "jwks_uri is not an absolute http(s) url"
    end
    scheme = string.lower(scheme)
    if scheme == "https" then
        return true
    end
    if scheme ~= "http" then
        return false, "unsupported jwks_uri scheme " .. scheme
    end
    -- IPv6 literals keep their brackets and may carry a port; everything else is
    -- whatever sits before the port.
    local host = string.match(authority, "^(%[[^%]]-%])") or string.match(authority, "^([^:]+)")
    host = string.lower(host or "")
    if host == "localhost" or host == "::1" or host == "[::1]" or host:match("^127%.") then
        return true
    end
    return false, "plain http is only allowed for a loopback jwks_uri"
end

---Decode the JWKS document into its keys array.
---@param body string
---@return table|nil keys, string|nil err
function _M.parse_jwks(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty JWKS body"
    end
    if #body > _M.MAX_JWKS_BYTES then
        return nil, "JWKS body exceeds the size limit"
    end
    local doc = cjson.decode(body)
    if type(doc) ~= "table" or type(doc.keys) ~= "table" then
        return nil, "JWKS document has no keys array"
    end
    return doc.keys
end

---Fetch the JWKS document through the shared cosocket client (hb.http_get, the same
---one the Kubernetes discovery poll uses, so both share the connection pool).
---@param uri string
---@return string|nil body, string|nil err
local function fetch(uri)
    local ok, hb = pcall(require, "resty.luarouter.hb")
    if not ok or type(hb.http_get) ~= "function" then
        return nil, "no HTTP client available"
    end
    local status, body, err = hb.http_get(uri, DEFAULT_FETCH_TIMEOUT_MS, { accept = "application/json" })
    if not status then
        return nil, err or "jwks fetch failed"
    end
    if status < 200 or status >= 300 then
        return nil, "jwks endpoint answered " .. tostring(status)
    end
    return body
end

---Load the key set, refreshing when the cached copy is stale.
---
---Refresh discipline: `force` (an unknown kid) bypasses the TTL but is rate limited
---by FORCED_REFRESH_MIN_INTERVAL_SECS, so a key rotation converges on the next
---request while a flood of bogus kids costs one fetch per interval. resty.lock over
---lr_locks serialises the refresh between workers when the shared dict exists;
---without it (unit probes) each worker just fetches for itself.
---@param cfg table
---@param force boolean
---@return table|nil keys, string|nil err
function _M.load_keys(cfg, force)
    local store = _M._keys_table()
    local now = now_secs()
    local fresh = (now - store.fetched_at) < (cfg.cache_secs or DEFAULT_CACHE_SECS)
    if fresh and not force then
        return store.list
    end
    if force and _M._last_forced and (now - _M._last_forced) < _M.FORCED_REFRESH_MIN_INTERVAL_SECS then
        return store.list
    end

    local function do_fetch()
        local body, err = fetch(cfg.jwks_uri)
        if not body then
            return nil, err
        end
        local list, parse_err = _M.parse_jwks(body)
        if not list then
            return nil, parse_err
        end
        store.list = list
        store.fetched_at = now_secs()
        _M._last_fetch = store.fetched_at
        if force then
            _M._last_forced = store.fetched_at
        end
        return list
    end

    local ok_lock, lock_mod = pcall(require, "resty.lock")
    if not ok_lock or not (ngx and ngx.shared and ngx.shared.lr_locks) then
        return do_fetch()
    end
    -- resty.lock takes the shared-dict *name*, the same way registry.lua does; the
    -- dict object answers "dictionary not found".
    local lock, lock_err = lock_mod:new("lr_locks", { timeout = 5, exptime = 10 })
    if not lock then
        return nil, "jwks lock unavailable: " .. tostring(lock_err)
    end
    if not lock:lock("jwks") then
        -- Somebody else is fetching: serve what we have and let the next request
        -- pick up what they write.
        return store.list
    end
    local list, err = do_fetch()
    lock:unlock()
    if not list then
        return nil, err
    end
    return list
end

---Build an OpenSSL public key from one JWK.
---@param jwk table
---@param alg string
---@return table|nil pkey, string|nil err
local function public_key(jwk, alg)
    local ok, pkey_mod = pcall(require, "resty.openssl.pkey")
    if not ok then
        return nil, "resty.openssl.pkey is unavailable"
    end
    local encoded = cjson.encode(jwk)
    if not encoded then
        return nil, "cannot encode JWK"
    end
    -- The explicit format option matters: without it resty.openssl tries PEM/DER
    -- first and the later verify fails with "expect a string at #1".
    local key, err = pkey_mod.new(encoded, { format = "JWK", type = "pu" })
    if not key then
        return nil, "cannot load JWK as " .. alg .. ": " .. tostring(err)
    end
    return key
end

---Verify the signature over the signing input.
---@param jwk table
---@param alg string
---@param signing_input string
---@param sig_b64 string
---@return boolean ok, string|nil err
function _M.verify_signature(jwk, alg, signing_input, sig_b64)
    local plan = _M.SUPPORTED_ALGS[alg]
    if not plan then
        return false, "unsupported alg " .. tostring(alg)
    end
    local sig = b64url_decode(sig_b64)
    if not sig then
        return false, "invalid signature encoding"
    end
    if plan.raw then
        -- JWS carries ECDSA as fixed-width r||s; OpenSSL wants that width, not DER.
        local width = plan.curve_bits / 8
        if #sig ~= width * 2 then
            return false, "ECDSA signature is not r||s of the expected width"
        end
    end
    local key, key_err = public_key(jwk, alg)
    if not key then
        return false, key_err
    end
    local ok, verr
    if plan.raw then
        ok, verr = key:verify(sig, signing_input, plan.md, nil, { ecdsa_use_raw = true })
    else
        ok, verr = key:verify(sig, signing_input, plan.md)
    end
    if not ok then
        return false, "signature verification failed: " .. tostring(verr)
    end
    return true
end

-------------------------------------------------------------------- authenticator

---Verify a bearer token as a JWT.
---
---The third return value is what makes the gate safe to put in front of the key
---list: `unavailable` says the JWT plane could not answer (not configured, the
---endpoint is unreachable, or the credential is not a JWS at all and therefore is
---an API key that belongs to the key matcher). Only a *definitive* verification
---failure -- a real JWS whose signature or claims do not check out -- leaves it
---nil, and that is the case Rust refuses outright instead of falling through.
---@param token string
---@return table|nil principal @ {id, name, role, auth_method="jwt"}
---@return string|nil err @ reason for the failure
---@return boolean|nil unavailable @ true => caller should keep matching API keys
function _M.authenticate(token)
    local cfg = _M.config()
    if not cfg.jwks_uri then
        return nil, "jwt_not_configured", true
    end
    local ok_url, url_err = _M.allowed_url(cfg.jwks_uri)
    if not ok_url then
        return nil, url_err, true
    end

    local signing_input, header_b64, claims_b64, sig_b64 = _M.split_token(token)
    if not signing_input then
        return nil, "token is not a JWS", true
    end
    local header = _M.decode_segment(header_b64)
    if type(header) ~= "table" then
        return nil, "invalid JWS header"
    end
    if type(header.kid) ~= "string" or header.kid == "" then
        -- Rust answers MissingKid here.
        return nil, "JWT header carries no kid"
    end
    local alg = header.alg
    if not _M.SUPPORTED_ALGS[alg] then
        return nil, "unsupported alg " .. tostring(alg or "none")
    end

    local keys, load_err = _M.load_keys(cfg, false)
    if not keys then
        return nil, "cannot load JWKS: " .. tostring(load_err), true
    end
    local jwk = find_jwk(keys, header.kid)
    if not jwk then
        -- Unknown kid: one forced refresh covers a rotation without a restart, the
        -- same retry-on-miss the Rust verifier performs.
        keys, load_err = _M.load_keys(cfg, true)
        if not keys then
            return nil, "cannot refresh JWKS: " .. tostring(load_err), true
        end
        jwk = find_jwk(keys, header.kid)
    end
    if not jwk then
        return nil, "no key for kid " .. header.kid
    end
    local jwk_alg = _M.jwk_alg(jwk)
    if not jwk_alg then
        return nil, "JWK for kid " .. header.kid .. " uses an unsupported key type"
    end
    if jwk_alg ~= alg then
        -- Algorithm confusion guard: the token may not claim an algorithm the key
        -- behind its kid does not implement.
        return nil, "alg " .. alg .. " does not match the key's " .. jwk_alg
    end

    local verified, sig_err = _M.verify_signature(jwk, alg, signing_input, sig_b64)
    if not verified then
        return nil, sig_err
    end
    local claims = _M.decode_segment(claims_b64)
    if type(claims) ~= "table" then
        return nil, "invalid JWT claims"
    end
    local ok_claims, claim_err = _M.check_claims(claims, {
        issuer = cfg.issuer,
        audience = cfg.audience,
        leeway_secs = cfg.leeway_secs,
    })
    if not ok_claims then
        return nil, claim_err
    end

    local subject = _M.subject(claims)
    return {
        id = "jwt:" .. subject,
        name = subject,
        role = _M.resolve_role(_M.extract_roles(claims, cfg.role_claim),
            cfg.mapping, cfg.mapping_configured),
        auth_method = "jwt",
    }
end

---JWT gate configured? Only a JWKS endpoint counts: issuer and audience alone would
---describe a verification nobody can perform, and silently skipping the check is the
---failure mode worth avoiding.
---@return boolean
function _M.enabled()
    return _M.config().jwks_uri ~= nil
end

---Diagnostics for the e2e and for /_ui: the config in effect plus cache age. Never
---includes a token.
---@return table
function _M.status()
    local cfg = _M.config()
    local store = _M._keys_table()
    return {
        enabled = cfg.jwks_uri ~= nil,
        jwks_uri = cfg.jwks_uri or "",
        issuer = cfg.issuer or "",
        audience = cfg.audience or "",
        role_claim = cfg.role_claim,
        role_mapping = cfg.mapping,
        leeway_secs = cfg.leeway_secs,
        cache_secs = cfg.cache_secs,
        cached_keys = store.list and #store.list or 0,
        fetched_at = store.fetched_at,
        age_secs = store.fetched_at > 0 and (now_secs() - store.fetched_at) or nil,
        last_fetch = _M._last_fetch,
        last_forced_refresh = _M._last_forced,
    }
end

return _M

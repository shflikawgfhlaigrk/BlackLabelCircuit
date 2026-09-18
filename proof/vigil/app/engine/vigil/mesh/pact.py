"""M3 — Mutual Vigil Pact: two households exchange a one-bit daily
heartbeat ("normal pattern today: y/n") plus an alarm-only escalation
payload, end-to-end encrypted, serverless, over owner-controlled
transports.

Threat model (stated honestly)
------------------------------
- Content is sealed end-to-end: the transport provider (iCloud/Dropbox for
  FileDropTransport, the mail provider for SmtpImapTransport) sees only
  ciphertext envelopes. NOTHING about the household's day — not even the
  one bit — is readable in transit.
- Metadata IS visible to the transport provider: that two parties
  exchange one small blob per day, when, and (for email) the addresses.
  A daily heartbeat inherently leaks "the system was up".
- Authenticity: envelopes are AEAD-authenticated under a key derived from
  both parties' static keys; a third party cannot inject or alter
  messages without detection. Replays are rejected via a (day, nonce)
  cache; the day field tolerates ±1 day of clock skew between houses.
- Key exchange: static X25519 keys generated once per household and
  exchanged out of band (in person / any channel — public keys are
  public). Compromise of one household's private key exposes the channel;
  there is no forward secrecy (deliberate: no servers, no round trips).

Crypto backends
---------------
Primary (used automatically when the ``cryptography`` package is
importable): X25519 static-static ECDH -> HKDF-SHA256 -> ChaCha20-Poly1305
AEAD.

Stdlib-only STOPGAP fallback (see ``_StopgapBox``): Python's stdlib has
neither X25519 nor an AEAD, so the fallback degrades to a *pre-shared
secret* model (the "public key" you exchange must be treated as a secret)
with an HKDF-SHA256 counter-mode XOR keystream + HMAC-SHA256 tag
(encrypt-then-MAC). It keeps the same envelope format and tests, but it
is NOT production crypto. TODO: require ``cryptography`` in production
installs and delete the stopgap.
"""

from __future__ import annotations

import base64
import hmac
import hashlib
import json
import os
import secrets
import time
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

SCHEME_X25519 = "x25519-chacha20poly1305"
SCHEME_STOPGAP = "psk-hkdf-xor-stopgap"
_INFO = b"vigil-pact-v1"
SKEW_DAYS = 1                      # accepted |message day - local day|
MAX_AGE_DAYS = 400                 # replay-cache pruning horizon


class PactError(ValueError):
    """Tampered, replayed, malformed or out-of-window pact message."""


_CRYPTO_OK: bool | None = None


def _have_cryptography() -> bool:
    """True only when the primitives we need actually work.

    ``import cryptography`` succeeding is not enough: a broken install
    (e.g. missing ``_cffi_backend``) imports at top level but panics in
    the Rust bindings on first real use — so probe the exact primitives.
    pyo3's PanicException may not subclass Exception, hence the broad
    catch (deliberate, and confined to this probe).
    """
    global _CRYPTO_OK
    if _CRYPTO_OK is None:
        try:  # optional dep, guarded per CONTRACTS.md §7
            from cryptography.hazmat.primitives.asymmetric.x25519 import (  # noqa: F401, PLC0415
                X25519PrivateKey,
            )
            from cryptography.hazmat.primitives.ciphers.aead import (  # noqa: F401, PLC0415
                ChaCha20Poly1305,
            )
            ChaCha20Poly1305(b"\x00" * 32).encrypt(b"\x00" * 12, b"probe", b"")
            _CRYPTO_OK = True
        except BaseException:  # noqa: BLE001 — see docstring
            _CRYPTO_OK = False
    return _CRYPTO_OK


# ---------------------------------------------------------------------------
# HKDF-SHA256 (stdlib) — shared by both backends
# ---------------------------------------------------------------------------

def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    prk = hmac.new(salt or b"\x00" * 32, ikm, hashlib.sha256).digest()
    out, block = b"", b""
    counter = 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

@dataclass
class PactIdentity:
    """Static household keypair, generated once.

    ``scheme`` is SCHEME_X25519 (public key is safely public) or
    SCHEME_STOPGAP (the "public" key doubles as a pre-shared secret —
    exchange it over a secure channel; see module docstring).
    """

    scheme: str
    private: bytes   # 32 bytes
    public: bytes    # 32 bytes

    def save(self, path: str | Path) -> Path:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        blob = json.dumps({"scheme": self.scheme,
                           "private": self.private.hex(),
                           "public": self.public.hex()}) + "\n"
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(blob)
        os.chmod(p, 0o600)
        return p

    @classmethod
    def load(cls, path: str | Path) -> "PactIdentity":
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls(scheme=raw["scheme"], private=bytes.fromhex(raw["private"]),
                   public=bytes.fromhex(raw["public"]))


def generate_identity(force_stdlib: bool = False) -> PactIdentity:
    if _have_cryptography() and not force_stdlib:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives import serialization

        key = X25519PrivateKey.generate()
        priv = key.private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        pub = key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw,
        )
        return PactIdentity(SCHEME_X25519, priv, pub)
    # STOPGAP: no DH in the stdlib — the exchanged "public" key IS the
    # secret (pre-shared-secret model). See module docstring.
    seed = secrets.token_bytes(32)
    return PactIdentity(SCHEME_STOPGAP, seed, seed)


# ---------------------------------------------------------------------------
# Seal/open backends
# ---------------------------------------------------------------------------

class _X25519Box:
    NONCE_LEN = 12

    def __init__(self, identity: PactIdentity, peer_pubkey: bytes) -> None:
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey, X25519PublicKey,
        )

        shared = X25519PrivateKey.from_private_bytes(identity.private).exchange(
            X25519PublicKey.from_public_bytes(peer_pubkey)
        )
        # Salt over the *sorted* public keys so both ends derive one key.
        salt = b"".join(sorted((identity.public, peer_pubkey)))
        self._key = hkdf_sha256(shared, salt, _INFO, 32)

    def seal(self, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

        return ChaCha20Poly1305(self._key).encrypt(nonce, plaintext, aad)

    def open(self, nonce: bytes, ciphertext: bytes, aad: bytes) -> bytes:
        from cryptography.exceptions import InvalidTag
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

        try:
            return ChaCha20Poly1305(self._key).decrypt(nonce, ciphertext, aad)
        except InvalidTag as exc:
            raise PactError("AEAD authentication failed (tampered?)") from exc


class _StopgapBox:
    """STDLIB-ONLY STOPGAP — NOT PRODUCTION CRYPTO.

    XOR keystream from HKDF-SHA256 in counter mode + HMAC-SHA256 tag
    (encrypt-then-MAC over aad|nonce|ct). Confidentiality and integrity
    are only as good as the secrecy of the exchanged seed keys (there is
    no DH here — see module docstring). TODO: require ``cryptography`` in
    production and remove this class.
    """

    NONCE_LEN = 16
    TAG_LEN = 32

    def __init__(self, identity: PactIdentity, peer_pubkey: bytes) -> None:
        ikm = b"".join(sorted((identity.private, peer_pubkey)))
        salt = b"vigil-pact-stopgap"
        self._enc_key = hkdf_sha256(ikm, salt, _INFO + b"|enc", 32)
        self._mac_key = hkdf_sha256(ikm, salt, _INFO + b"|mac", 32)

    def _keystream(self, nonce: bytes, n: int) -> bytes:
        out = b""
        counter = 0
        while len(out) < n:
            out += hmac.new(self._enc_key,
                            nonce + counter.to_bytes(4, "little"),
                            hashlib.sha256).digest()
            counter += 1
        return out[:n]

    def seal(self, nonce: bytes, plaintext: bytes, aad: bytes) -> bytes:
        ct = bytes(a ^ b for a, b in zip(plaintext, self._keystream(nonce, len(plaintext))))
        tag = hmac.new(self._mac_key, aad + nonce + ct, hashlib.sha256).digest()
        return ct + tag

    def open(self, nonce: bytes, ciphertext: bytes, aad: bytes) -> bytes:
        if len(ciphertext) < self.TAG_LEN:
            raise PactError("short ciphertext")
        ct, tag = ciphertext[:-self.TAG_LEN], ciphertext[-self.TAG_LEN:]
        expect = hmac.new(self._mac_key, aad + nonce + ct, hashlib.sha256).digest()
        if not hmac.compare_digest(tag, expect):
            raise PactError("HMAC authentication failed (tampered?)")
        return bytes(a ^ b for a, b in zip(ct, self._keystream(nonce, len(ct))))


# ---------------------------------------------------------------------------
# Pact — sealed heartbeat/alarm messages with replay + skew handling
# ---------------------------------------------------------------------------

class Pact:
    """One side of a mutual vigil pact.

    ``identity`` is this household's static keypair; ``peer_pubkey`` the
    other household's public key (bytes). Messages are dicts sealed into
    JSON envelopes (bytes) safe to hand to any transport.
    """

    def __init__(self, identity: PactIdentity, peer_pubkey: bytes,
                 now_fn: Callable[[], float] = time.time) -> None:
        self.identity = identity
        self.peer_pubkey = peer_pubkey
        self.now_fn = now_fn
        if identity.scheme == SCHEME_X25519:
            self._box = _X25519Box(identity, peer_pubkey)
        elif identity.scheme == SCHEME_STOPGAP:
            self._box = _StopgapBox(identity, peer_pubkey)
        else:
            raise ValueError(f"unknown pact scheme {identity.scheme!r}")
        self.scheme = identity.scheme
        self._replay: set[tuple[str, str]] = set()   # (day, nonce) seen

    # -- day helpers --------------------------------------------------------

    def _today(self) -> date:
        return datetime.fromtimestamp(self.now_fn(), tz=timezone.utc).date()

    @staticmethod
    def day_str(d: date) -> str:
        return d.isoformat()

    # -- seal / open --------------------------------------------------------

    def seal(self, message: dict) -> bytes:
        """Seal one message dict into an envelope (bytes)."""
        nonce = secrets.token_bytes(self._box.NONCE_LEN)
        aad = f"{self.scheme}|{self.identity.public.hex()}".encode()
        pt = json.dumps(message, separators=(",", ":"), sort_keys=True).encode()
        ct = self._box.seal(nonce, pt, aad)
        env = {
            "v": 1,
            "alg": self.scheme,
            "sender": self.identity.public.hex(),
            "nonce": base64.b64encode(nonce).decode(),
            "ct": base64.b64encode(ct).decode(),
        }
        return json.dumps(env, separators=(",", ":")).encode()

    def open(self, envelope: bytes) -> dict:
        """Open + authenticate an envelope. Raises PactError on tamper /
        malformed input. Does NOT apply replay/skew policy (see receive)."""
        try:
            env = json.loads(envelope.decode("utf-8"))
            alg = env["alg"]
            sender = bytes.fromhex(env["sender"])
            nonce = base64.b64decode(env["nonce"])
            ct = base64.b64decode(env["ct"])
        except (ValueError, KeyError, UnicodeDecodeError) as exc:
            raise PactError(f"malformed envelope: {exc}") from exc
        if alg != self.scheme:
            raise PactError(f"scheme mismatch: {alg!r} != {self.scheme!r}")
        if sender != self.peer_pubkey and sender != self.identity.public:
            raise PactError("envelope not from our peer")
        aad = f"{alg}|{env['sender']}".encode()
        pt = self._box.open(nonce, ct, aad)
        try:
            return json.loads(pt.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise PactError("bad plaintext") from exc

    # -- message construction ------------------------------------------------

    def heartbeat(self, normal: bool, day: str | None = None) -> bytes:
        """Daily one-bit heartbeat. By design the payload carries the day,
        one bit, a nonce and a timestamp — no rooms, no vitals, no counts."""
        msg = {
            "type": "heartbeat",
            "day": day or self.day_str(self._today()),
            "normal": bool(normal),
            "nonce": uuid.uuid4().hex,
            "ts": float(self.now_fn()),
        }
        return self.seal(msg)

    def alarm(self, kind: str, room: str, t: float, confidence: float) -> bytes:
        """Alarm-only escalation payload — the ONLY message that carries
        anything beyond the one bit, and it is sent only on alarm."""
        msg = {
            "type": "alarm",
            "day": self.day_str(self._today()),
            "kind": str(kind),
            "room": str(room),
            "t": float(t),
            "confidence": float(confidence),
            "nonce": uuid.uuid4().hex,
            "ts": float(self.now_fn()),
        }
        return self.seal(msg)

    # -- receive policy: replay + clock skew ---------------------------------

    def receive(self, envelope: bytes) -> dict:
        """Open an envelope and enforce replay/skew policy.

        Raises PactError on tamper, replay, or a day more than ±SKEW_DAYS
        from the local date.
        """
        msg = self.open(envelope)
        day_s = str(msg.get("day", ""))
        nonce = str(msg.get("nonce", ""))
        if not day_s or not nonce:
            raise PactError("message missing day/nonce")
        try:
            msg_day = date.fromisoformat(day_s)
        except ValueError as exc:
            raise PactError(f"bad day {day_s!r}") from exc
        today = self._today()
        if abs((msg_day - today).days) > SKEW_DAYS:
            raise PactError(f"day {day_s} outside ±{SKEW_DAYS}d of {today}")
        key = (day_s, nonce)
        if key in self._replay:
            raise PactError("replayed message")
        self._replay.add(key)
        self._prune(today)
        return msg

    def _prune(self, today: date) -> None:
        if len(self._replay) > 4096:
            floor = today - timedelta(days=MAX_AGE_DAYS)
            self._replay = {
                (d, n) for d, n in self._replay
                if d >= floor.isoformat()
            }


# ---------------------------------------------------------------------------
# Transports — owner-controlled, pluggable
# ---------------------------------------------------------------------------

class LoopbackTransport:
    """In-memory pair for tests. ``LoopbackTransport.pair()`` returns two
    ends; blobs sent on one are received on the other."""

    def __init__(self) -> None:
        self._inbox: list[bytes] = []
        self._peer: "LoopbackTransport | None" = None

    @classmethod
    def pair(cls) -> tuple["LoopbackTransport", "LoopbackTransport"]:
        a, b = cls(), cls()
        a._peer, b._peer = b, a
        return a, b

    def send(self, blob: bytes) -> None:
        assert self._peer is not None, "unpaired loopback"
        self._peer._inbox.append(bytes(blob))

    def recv(self) -> list[bytes]:
        out, self._inbox = self._inbox, []
        return out


class FileDropTransport:
    """Shared-folder transport (iCloud Drive / Dropbox / Syncthing…).

    Each side writes ``<me>-to-<peer>-<uuid>.pact`` files into the shared
    folder and consumes (reads + deletes) files addressed to it. The
    folder provider sees only sealed envelopes (metadata caveat in the
    module docstring).
    """

    def __init__(self, folder: str | Path, me: str, peer: str) -> None:
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.me, self.peer = str(me), str(peer)

    def send(self, blob: bytes) -> Path:
        name = f"{self.me}-to-{self.peer}-{uuid.uuid4().hex}.pact"
        tmp = self.folder / (name + ".tmp")
        tmp.write_bytes(blob)
        final = self.folder / name
        tmp.rename(final)   # atomic-ish: sync clients never see partials
        return final

    def recv(self) -> list[bytes]:
        out: list[bytes] = []
        prefix = f"{self.peer}-to-{self.me}-"
        for p in sorted(self.folder.glob(prefix + "*.pact")):
            try:
                out.append(p.read_bytes())
                p.unlink()
            except OSError:
                continue   # sync race — retry next poll
        return out


class SmtpImapTransport:
    """Email transport (guarded): sealed envelopes as base64 message
    bodies with subject ``[vigil-pact] <me>``.

    Config carries env-var NAMES only (never values), matching the
    AlertsConfig convention. Both ends need SMTP submit + IMAP fetch
    credentials in the environment; without them every call raises with a
    clear message. Deployment-gated: not exercised by tests.
    """

    SUBJECT = "[vigil-pact]"

    def __init__(self, me: str, peer_addr: str,
                 smtp_host_env: str = "VIGIL_PACT_SMTP_HOST",
                 imap_host_env: str = "VIGIL_PACT_IMAP_HOST",
                 user_env: str = "VIGIL_PACT_USER",
                 password_env: str = "VIGIL_PACT_PASSWORD") -> None:
        self.me = me
        self.peer_addr = peer_addr
        self.env_names = {
            "smtp_host": smtp_host_env, "imap_host": imap_host_env,
            "user": user_env, "password": password_env,
        }

    def _env(self, key: str) -> str:
        name = self.env_names[key]
        val = os.environ.get(name, "")
        if not val:
            raise RuntimeError(
                f"SmtpImapTransport needs ${name} set (env-var names only "
                f"live in config; values come from the environment)")
        return val

    def send(self, blob: bytes) -> None:
        import smtplib
        from email.message import EmailMessage

        msg = EmailMessage()
        msg["From"] = self._env("user")
        msg["To"] = self.peer_addr
        msg["Subject"] = f"{self.SUBJECT} {self.me}"
        msg.set_content(base64.b64encode(blob).decode())
        with smtplib.SMTP_SSL(self._env("smtp_host")) as smtp:
            smtp.login(self._env("user"), self._env("password"))
            smtp.send_message(msg)

    def recv(self) -> list[bytes]:
        import imaplib
        import email

        out: list[bytes] = []
        with imaplib.IMAP4_SSL(self._env("imap_host")) as imap:
            imap.login(self._env("user"), self._env("password"))
            imap.select("INBOX")
            _, data = imap.search(None, "UNSEEN", "SUBJECT", self.SUBJECT)
            for num in (data[0].split() if data and data[0] else []):
                _, fetched = imap.fetch(num, "(RFC822)")
                body = email.message_from_bytes(fetched[0][1]).get_payload()
                try:
                    out.append(base64.b64decode(body))
                except (ValueError, TypeError):
                    continue
        return out


# ---------------------------------------------------------------------------
# PactChannel — pact + transport
# ---------------------------------------------------------------------------

class PactChannel:
    """Glue: seal on the way out, verify/replay-check on the way in.

    ``poll()`` returns the verified message dicts (heartbeats + alarms);
    anything failing authentication/replay/skew lands in ``self.rejected``
    as (envelope, reason) and is never surfaced as data.
    """

    def __init__(self, pact: Pact, transport) -> None:
        self.pact = pact
        self.transport = transport
        self.rejected: list[tuple[bytes, str]] = []

    def send_heartbeat(self, normal: bool, day: str | None = None) -> None:
        self.transport.send(self.pact.heartbeat(normal, day=day))

    def send_alarm(self, kind: str, room: str, t: float, confidence: float) -> None:
        self.transport.send(self.pact.alarm(kind, room, t, confidence))

    def poll(self) -> list[dict]:
        out: list[dict] = []
        for blob in self.transport.recv():
            try:
                out.append(self.pact.receive(blob))
            except PactError as exc:
                self.rejected.append((blob, str(exc)))
        return out

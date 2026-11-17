"""DeviceDesk HTTPS bridge. Explicit operations only; no shell or script API."""
from __future__ import annotations
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from pydantic import BaseModel, ConfigDict, Field
import uvicorn

ROOT = Path(__file__).resolve().parent
ACTIONS = {"Inventory", "DriverUpdates", "PopupMessage", "TempPreview", "TempDelete", "TempDiscard", "Restart", "Trim", "DirectorySearch", "DirectoryUnlock", "DirectoryResetPassword"}
WRITES = {"PopupMessage", "TempDelete", "Restart", "Trim", "DirectoryUnlock", "DirectoryResetPassword"}
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")

class JobRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    requestId: uuid.UUID
    action: str = Field(max_length=40)
    target: str = Field(default="", max_length=253)
    payload: dict = Field(default_factory=dict)
    confirmed: bool = False

def check_config(config):
    if not config.get("operators") or not config.get("allowedHosts"):
        raise ValueError("Configure operators and allowedHosts first.")
    names = set()
    for operator in config["operators"]:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", operator.get("id", "")) or operator["id"] in names:
            raise ValueError("Operator IDs must be unique.")
        names.add(operator["id"])
        if not re.fullmatch(r"[a-f0-9]{64}", operator.get("tokenSHA256", "")):
            raise ValueError("Replace each placeholder with a generated token SHA256.")
        if not set(operator.get("actions", [])) <= ACTIONS:
            raise ValueError("Unknown permitted action.")
        if any(not HOST.fullmatch(t) for t in operator.get("targets", [])):
            raise ValueError("Use exact target hostnames/FQDNs, without wildcards.")
    if config.get("directoryServer") and not HOST.fullmatch(config["directoryServer"]):
        raise ValueError("Invalid directory server.")

def validate_payload(action, payload):
    fields = {
        "Inventory": set(), "DriverUpdates": set(), "Restart": set(), "TempPreview": set(),
        "TempDelete": {"PreviewId", "Hash"}, "TempDiscard": {"PreviewId", "Hash"},
        "PopupMessage": {"Title", "Message", "Seconds"}, "Trim": {"Id", "StartTicks"},
        "DirectorySearch": {"Query", "Kind"},
        "DirectoryUnlock": {"ObjectGUID", "DistinguishedName", "SamAccountName"},
        "DirectoryResetPassword": {"ObjectGUID", "DistinguishedName", "SamAccountName", "Password", "ChangeAtLogon"},
    }
    if set(payload) - fields[action]:
        raise HTTPException(422, "Unsupported payload fields.")
    def string(name, low, high):
        value = payload.get(name)
        if not isinstance(value, str) or not low <= len(value) <= high or "\0" in value:
            raise HTTPException(422, "Invalid " + name)
        return value
    if action == "PopupMessage":
        string("Title", 1, 100); string("Message", 1, 2000)
        if type(payload.get("Seconds")) is not int or not 10 <= payload["Seconds"] <= 300:
            raise HTTPException(422, "Seconds must be 10 to 300.")
    if action in {"TempDelete", "TempDiscard"}:
        if not re.fullmatch(r"[a-f0-9]{32}", string("PreviewId", 32, 32)) or not re.fullmatch(r"[a-fA-F0-9]{64}", string("Hash", 64, 64)):
            raise HTTPException(422, "Invalid preview reference.")
    if action == "Trim":
        for name in ("Id", "StartTicks"):
            # StartTicks arrives as a decimal string to preserve Int64 precision on mobile.
            value = payload.get(name)
            if isinstance(value, bool) or not re.fullmatch(r"[0-9]{1,19}", str(value)) or not 0 < int(value) <= 9223372036854775807:
                raise HTTPException(422, "Invalid process reference.")
    if action == "DirectorySearch":
        string("Query", 2, 128)
        if payload.get("Kind") not in {"Users", "Computers"}:
            raise HTTPException(422, "Select Users or Computers.")
    if action in {"DirectoryUnlock", "DirectoryResetPassword"}:
        try: uuid.UUID(string("ObjectGUID", 36, 36))
        except ValueError: raise HTTPException(422, "Invalid object GUID.")
        string("DistinguishedName", 1, 2048); string("SamAccountName", 1, 256)
    if action == "DirectoryResetPassword":
        string("Password", 1, 256)
        if type(payload.get("ChangeAtLogon")) is not bool:
            raise HTTPException(422, "Invalid ChangeAtLogon.")

class Store:
    def __init__(self, filename):
        self.filename = str(filename)
        self.lock = threading.RLock()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="DeviceDesk")
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, owner TEXT NOT NULL, request_id TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, result TEXT, error TEXT, UNIQUE(owner,request_id))")
            db.execute("UPDATE jobs SET state='unknown',error='Bridge restarted during the operation. Verify the target before repeating any action.' WHERE state IN ('queued','running')")
    def connect(self):
        db = sqlite3.connect(self.filename, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA secure_delete=ON")
        return db
    def record(self, job_id, owner):
        with self.connect() as db:
            db.execute("UPDATE jobs SET result=NULL,state='expired',error='Result expired. Verify the target before repeating.' WHERE id=? AND created < ? AND state IN ('succeeded','failed')", (job_id, time.time()-1800))
            row = db.execute("SELECT * FROM jobs WHERE id=? AND owner=?", (job_id, owner)).fetchone()
        if row is None: raise HTTPException(404, "Job not found.")
        result = json.loads(row["result"]) if row["result"] else None
        return {"id": row["id"], "action": row["action"], "target": row["target"], "state": row["state"], "result": result, "error": row["error"]}
    def submit(self, owner, request, runner):
        with self.lock, self.connect() as db:
            # Keep request identities; remove sensitive result bodies after 30 minutes.
            db.execute("UPDATE jobs SET result=NULL,state='expired',error='Result expired. Verify changes on the target before starting another action.' WHERE created < ? AND state IN ('succeeded','failed')", (time.time()-1800,))
            old = db.execute("SELECT id,action,target FROM jobs WHERE owner=? AND request_id=?", (owner, str(request.requestId))).fetchone()
            if old:
                if old["action"] != request.action or old["target"] != request.target:
                    raise HTTPException(409, "Request ID already used for another operation.")
                return old["id"]
            active = db.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','running')").fetchone()[0]
            if active >= 8: raise HTTPException(429, "Bridge busy. Wait for existing jobs.")
            ident = str(uuid.uuid4())
            db.execute("INSERT INTO jobs(id,owner,request_id,action,target,state,created) VALUES(?,?,?,?,?,'queued',?)", (ident, owner, str(request.requestId), request.action, request.target, time.time()))
            db.commit()
            self.pool.submit(self.execute, ident, request, runner)
            return ident
    def execute(self, ident, request, runner):
        with self.connect() as db: db.execute("UPDATE jobs SET state='running' WHERE id=?", (ident,))
        try:
            response = runner(request)
            state, result, error = "succeeded", json.dumps(response, ensure_ascii=False), None
        except subprocess.TimeoutExpired:
            state, result, error = "unknown", None, "Operation timed out. It may have run on the target. Verify before repeating."
        except Exception:
            # Do not return raw subprocess errors or request data: reset passwords can appear in exceptions.
            state, result, error = ("unknown" if request.action in WRITES else "failed"), None, "Windows operation could not be confirmed. Check bridge identity, connectivity, RSAT and permissions. Verify the target before repeating a change; no automatic retry was performed."
        finally:
            request.payload.clear()
        with self.connect() as db: db.execute("UPDATE jobs SET state=?,result=?,error=? WHERE id=?", (state, result, error, ident))

class WindowsRunner:
    def __init__(self, config): self.config = config
    def __call__(self, request):
        if os.name != "nt": raise RuntimeError("Windows bridge required")
        powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        envelope = {"Action": request.action, "Target": request.target, "Payload": request.payload, "DirectoryServer": self.config.get("directoryServer", ""), "WinRMHTTPS": self.config.get("winrmHTTPS", True)}
        result = subprocess.run([str(powershell), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "Run-Operation.ps1")], input=json.dumps(envelope), text=True, encoding="utf-8", capture_output=True, timeout=900, shell=False)
        if result.returncode: raise RuntimeError("Windows operation failed")
        parsed = json.loads(result.stdout.lstrip("\ufeff"))
        if not parsed.get("ok"): raise RuntimeError("Windows operation failed")
        return parsed["data"]

def create_app(config, database=None, runner=None):
    check_config(config)
    store = Store(database or ROOT / "jobs.sqlite3")
    run = runner or WindowsRunner(config)
    @asynccontextmanager
    async def lifespan(app):
        yield
        store.pool.shutdown(wait=True)
    app = FastAPI(title="DeviceDesk Bridge", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.store = store
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=config["allowedHosts"])
    @app.middleware("http")
    async def boundaries(request, call_next):
        if request.url.scheme != "https": return JSONResponse({"detail": "HTTPS required."}, 400)
        if request.headers.get("transfer-encoding"): return JSONResponse({"detail": "Chunked requests are not accepted."}, 400)
        try: length = int(request.headers.get("content-length", "0"))
        except ValueError: return JSONResponse({"detail": "Invalid request size."}, 400)
        if length < 0 or length > 16384: return JSONResponse({"detail": "Request too large."}, 413)
        if request.method == "POST" and (not length or request.headers.get("content-type", "").split(";")[0] != "application/json"):
            return JSONResponse({"detail": "JSON body required."}, 415)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response
    async def operator(request: Request):
        value = request.headers.get("authorization", "")
        if not value.startswith("Bearer ") or not 40 <= len(value[7:]) <= 512:
            raise HTTPException(401, "Invalid access token.")
        digest = hashlib.sha256(value[7:].encode()).hexdigest()
        for op in config["operators"]:
            if hmac.compare_digest(digest, op["tokenSHA256"]): return op
        raise HTTPException(401, "Invalid access token.")
    @app.get("/v1/capabilities")
    def capabilities(op=Depends(operator)):
        return {"apiVersion": 1, "operator": op["id"], "targets": op.get("targets", []), "actions": op.get("actions", []), "directoryServer": config.get("directoryServer", "")}
    @app.post("/v1/jobs", status_code=202)
    def submit(body: JobRequest, op=Depends(operator)):
        if body.action not in ACTIONS or body.action not in op.get("actions", []): raise HTTPException(403, "Action is not permitted for this operator.")
        if body.action in WRITES and not body.confirmed: raise HTTPException(409, "Explicit confirmation is required.")
        if body.action.startswith("Directory"):
            if not config.get("directoryServer"): raise HTTPException(409, "Directory server is not configured.")
            body.target = config["directoryServer"]
        else:
            matches = [t for t in op.get("targets", []) if t.casefold() == body.target.casefold()]
            if len(matches) != 1: raise HTTPException(403, "Target is not permitted.")
            body.target = matches[0]
        validate_payload(body.action, body.payload)
        ident = store.submit(op["id"], body, run)
        return {"id": ident}
    @app.get("/v1/requests/{request_id}")
    def lookup_request(request_id: uuid.UUID, op=Depends(operator)):
        with store.connect() as db:
            row = db.execute("SELECT id FROM jobs WHERE owner=? AND request_id=?", (op["id"], str(request_id))).fetchone()
        if row is None: raise HTTPException(404, "No record found for this request. Verify the target before repeating a change.")
        return {"id": row["id"]}
    @app.get("/v1/jobs/{job_id}")
    def get_job(job_id: uuid.UUID, op=Depends(operator)):
        return store.record(str(job_id), op["id"])
    # FastAPI's default validation response can echo password input. Replace it.
    from fastapi.exceptions import RequestValidationError
    @app.exception_handler(RequestValidationError)
    async def invalid(request, exc): return JSONResponse({"detail": "Invalid request fields."}, 422)
    return app

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=str(ROOT / "config.json"))
    parser.add_argument("--new-token", action="store_true")
    args = parser.parse_args()
    if args.new_token:
        token = secrets.token_urlsafe(32)
        print("iPhone access token (store privately): " + token)
        print("config tokenSHA256: " + hashlib.sha256(token.encode()).hexdigest())
    else:
        config_path = Path(args.config).resolve()
        cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
        if os.name != "nt": raise SystemExit("Live bridge requires Windows.")
        for field in ("certificate", "privateKey"):
            if not cfg.get(field): raise SystemExit("Configure an HTTPS certificate and private key.")
        app = create_app(cfg, database=config_path.parent / "jobs.sqlite3")
        uvicorn.run(app, host=cfg.get("bind", "127.0.0.1"), port=cfg.get("port", 9443), ssl_certfile=str(config_path.parent / cfg["certificate"]), ssl_keyfile=str(config_path.parent / cfg["privateKey"]), proxy_headers=False, access_log=False, workers=1, limit_concurrency=32, timeout_keep_alive=5)

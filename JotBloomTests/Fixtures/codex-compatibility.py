#!/usr/bin/python3
"""Offline app-server fixture. No credentials, network, or task execution."""
import json
import pathlib
import sys

base = pathlib.Path(__file__)
if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.0.0-fixture")
    sys.exit(0)
mode = base.with_suffix(".mode").read_text().strip()
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method", "")
    with base.with_suffix(".requests").open("a") as log:
        log.write(method + "\n")
    if "id" not in request:
        continue
    response = {"id": request["id"]}
    if method == "initialize":
        if mode == "handshake_error":
            response["error"] = {"code": -32603, "message": "fixture handshake failure"}
        else:
            response["result"] = {} if mode == "missing_handshake" else {"userAgent": "fixture", "futureField": 1}
    elif method == "account/read":
        if mode == "method_missing":
            response["error"] = {"code": -32601, "message": "fixture method missing"}
        elif mode == "missing_account_field":
            response["result"] = {"account": {"type": "apiKey"}}
        elif mode == "invalid_account":
            response["result"] = {"account": {}, "requiresOpenaiAuth": True}
        elif mode == "signed_out":
            response["result"] = {"account": None, "requiresOpenaiAuth": True}
        else:
            response["result"] = {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True, "futureField": 1}
    else:
        response["error"] = {"code": -32601, "message": "fixture has no task methods"}
    print(json.dumps(response), flush=True)

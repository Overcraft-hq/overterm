#!/usr/bin/env python3
"""A language server just big enough for LanguageServerTests.

Answers initialize, completion, hover, definition, references,
documentSymbol and formatting with fixed shapes real servers use; publishes
diagnostics after didOpen; asks workspace/configuration. Hover at line 99
never answers (a timeout); hover at line 666 exits at once (a crash).
Every message it gets is logged, one line each, to the file in argv[1].
"""
import json
import os
import sys

log_path = sys.argv[1]
stdin = sys.stdin.buffer
stdout = sys.stdout.buffer


def log(line):
    with open(log_path, "a") as f:
        f.write(line + "\n")


def send(message):
    body = json.dumps(message).encode()
    stdout.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    stdout.flush()


def reply(msg, result):
    send({"jsonrpc": "2.0", "id": msg["id"], "result": result})


def rng(l1, c1, l2, c2):
    return {"start": {"line": l1, "character": c1}, "end": {"line": l2, "character": c2}}


def read():
    length = None
    while True:
        line = stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.decode().partition(":")
        if name.lower() == "content-length":
            length = int(value.strip())
    return json.loads(stdin.read(length))


sys.stderr.write("fake-lsp: started\n")
sys.stderr.flush()

while True:
    msg = read()
    if msg is None:
        break
    method = msg.get("method")
    params = msg.get("params") or {}
    if method is None:
        log("response %s %s" % (msg.get("id"), json.dumps(msg.get("result"))))
        continue
    log(method)
    if method == "initialize":
        log("rootUri " + params.get("rootUri", ""))
        reply(msg, {
            "capabilities": {
                "textDocumentSync": {"openClose": True, "change": 2, "save": {"includeText": True}},
                "completionProvider": {"triggerCharacters": [".", ":"]},
                "hoverProvider": True,
                "definitionProvider": True,
                "referencesProvider": {},
                "documentSymbolProvider": True,
                "documentFormattingProvider": True,
            },
            "serverInfo": {"name": "fake"},
        })
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        log("open %s %s %d" % (doc["uri"], doc["languageId"], doc["version"]))
        send({"jsonrpc": "2.0", "id": "cfg-1", "method": "workspace/configuration",
              "params": {"items": [{"section": "a"}, {"section": "b"}]}})
        send({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 3, "message": "hi"}})
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
            "uri": doc["uri"],
            "diagnostics": [{"range": rng(0, 0, 0, 3), "severity": 2, "code": 42, "source": "fake", "message": "unused"}],
        }})
    elif method == "textDocument/didChange":
        log("change %d %s" % (params["textDocument"]["version"], json.dumps(params["contentChanges"])))
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
              "params": {"uri": params["textDocument"]["uri"], "diagnostics": []}})
    elif method == "textDocument/didSave":
        log("save " + params.get("text", "<none>"))
    elif method == "textDocument/completion":
        trigger = (params.get("context") or {}).get("triggerCharacter", "")
        reply(msg, {"isIncomplete": True, "items": [
            {"label": "Println", "kind": 3, "detail": "trigger=" + trigger,
             "textEdit": {"newText": "Println", "insert": rng(1, 4, 1, 6), "replace": rng(1, 4, 1, 10)}},
            {"label": "fmt.Sprintf", "kind": 3, "insertTextFormat": 2, "insertText": "Sprintf(${1:format})$0",
             "documentation": {"kind": "markdown", "value": "Formats **things**."},
             "additionalTextEdits": [{"range": rng(0, 0, 0, 0), "newText": "import \"fmt\"\n"}]},
            {"kind": 1},
        ]})
    elif method == "textDocument/hover":
        line = params["position"]["line"]
        if line == 666:
            os._exit(3)
        if line == 99:
            continue
        reply(msg, {"contents": [{"language": "go", "value": "func Println(a ...any)"}, "Prints."], "range": rng(1, 4, 1, 11)})
    elif method == "textDocument/definition":
        reply(msg, [{"targetUri": "file:///tmp/fake%20dir/def.go", "targetRange": rng(10, 0, 12, 1),
                     "targetSelectionRange": rng(10, 5, 10, 12)}])
    elif method == "textDocument/references":
        uri = params["textDocument"]["uri"]
        reply(msg, [{"uri": uri, "range": rng(1, 4, 1, 11)}, {"uri": uri, "range": rng(3, 0, 3, 7)}])
    elif method == "textDocument/documentSymbol":
        reply(msg, [{"name": "Server", "kind": 23, "range": rng(0, 0, 5, 1), "selectionRange": rng(0, 5, 0, 11),
                     "children": [{"name": "Start", "kind": 6, "detail": "func()", "range": rng(1, 1, 2, 1),
                                   "selectionRange": rng(1, 6, 1, 11)}]}])
    elif method == "textDocument/formatting":
        log("format %s %s" % (params["options"]["tabSize"], params["options"]["insertSpaces"]))
        reply(msg, [{"range": rng(0, 0, 0, 2), "newText": "\t"}])
    elif method == "shutdown":
        reply(msg, None)
    elif method == "exit":
        sys.exit(0)

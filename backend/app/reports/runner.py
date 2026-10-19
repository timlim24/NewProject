"""Runner script to execute Lambda handlers inside the container.

Supports both:
1. Lambda Web Adapter (receives HTTP POST /events on port 8000).
2. Native AWS Lambda Runtime API (http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/...).
"""

import http.server
import importlib
import json
import logging
import os
import sys
import threading
import urllib.error
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("runner")


def load_handler(handler_path: str):
    module_name, func_name = handler_path.rsplit(".", 1)
    mod = importlib.import_module(module_name)
    return getattr(mod, func_name)


class HandlerServer(http.server.HTTPServer):
    def __init__(self, server_address, RequestHandlerClass, handler_fn):
        self.handler_fn = handler_fn
        super().__init__(server_address, RequestHandlerClass)


class LambdaHTTPRequestHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress noisy default http access logs for readiness checks
        if "GET" in (args[0] if args else ""):
            return
        super().log_message(format, *args)

    def do_GET(self):
        # Health check endpoints for Lambda Web Adapter
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status": "ready"}')

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS, GET")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length)

        try:
            raw_str = post_data.decode("utf-8") if post_data else "{}"
            parsed_json = json.loads(raw_str) if raw_str else {}
        except Exception:
            parsed_json = {}

        # If incoming event is already a Lambda envelope (e.g. from SQS or direct invoke), keep it.
        # Otherwise wrap it in a Lambda HTTP event envelope so handlers get headers and body
        if isinstance(parsed_json, dict) and ("headers" in parsed_json or "Records" in parsed_json):
            event = parsed_json
        else:
            headers = {k.lower(): v for k, v in self.headers.items()}
            event = {
                "headers": headers,
                "body": raw_str,
                "httpMethod": "POST",
                "path": self.path,
            }

        try:
            handler_fn = self.server.handler_fn
            result = handler_fn(event, None)

            # If handler returned an APIGateway/Function URL style dict with statusCode
            if isinstance(result, dict) and "statusCode" in result:
                self.send_response(result.get("statusCode", 200))
                for h_k, h_v in result.get("headers", {}).items():
                    self.send_header(h_k, h_v)
                self.end_headers()
                body_out = result.get("body", "")
                if isinstance(body_out, str):
                    self.wfile.write(body_out.encode("utf-8"))
                else:
                    self.wfile.write(json.dumps(body_out).encode("utf-8"))
                return

            res_bytes = json.dumps(result or {}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(res_bytes)
        except Exception as e:
            logger.exception("Error executing Lambda handler: %s", e)
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))


def run_http_server(handler_fn, port: int):
    server = HandlerServer(("0.0.0.0", port), LambdaHTTPRequestHandler, handler_fn)
    logger.info("Lambda handler HTTP adapter listening on 0.0.0.0:%d", port)
    server.serve_forever()


def run_runtime_api(handler_fn, runtime_api: str):
    logger.info("Starting native Lambda Runtime API loop on %s", runtime_api)
    base_url = f"http://{runtime_api}/2018-06-01/runtime"

    while True:
        try:
            req = urllib.request.Request(f"{base_url}/invocation/next")
            with urllib.request.urlopen(req) as resp:
                inv_id = resp.headers.get("Lambda-Runtime-Aws-Request-Id")
                body = resp.read().decode("utf-8")
                event = json.loads(body)

            try:
                result = handler_fn(event, None)
                res_bytes = json.dumps(result or {}).encode("utf-8")
                post_req = urllib.request.Request(
                    f"{base_url}/invocation/{inv_id}/response",
                    data=res_bytes,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                urllib.request.urlopen(post_req)
            except Exception as e:
                logger.exception("Handler failed for invocation %s: %s", inv_id, e)
                err_bytes = json.dumps({"errorMessage": str(e), "errorType": type(e).__name__}).encode("utf-8")
                err_req = urllib.request.Request(
                    f"{base_url}/invocation/{inv_id}/error",
                    data=err_bytes,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                urllib.request.urlopen(err_req)
        except Exception as e:
            logger.error("Error in Runtime API loop: %s", e)


def main():
    handler_path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("LAMBDA_HANDLER", "app.reports.lambda_handler.handler")
    logger.info("Loading handler: %s", handler_path)
    handler_fn = load_handler(handler_path)

    primary_port = int(os.environ.get("AWS_LWA_PORT", os.environ.get("PORT", "8080")))
    alt_port = 8000 if primary_port == 8080 else 8080

    logger.info("Starting Lambda handler HTTP adapter on ports %d and %d", primary_port, alt_port)

    # Start listener on alternate port in background thread so both 8080 and 8000 respond
    try:
        t = threading.Thread(target=run_http_server, args=(handler_fn, alt_port), daemon=True)
        t.start()
    except Exception as e:
        logger.warning("Could not start listener on alt port %d: %s", alt_port, e)

    run_http_server(handler_fn, primary_port)


if __name__ == "__main__":
    main()

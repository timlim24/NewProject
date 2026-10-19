"""Lambda handler for agenda parsing endpoint."""

from collections import namedtuple
from datetime import date
import json
import logging
import os
import time
import urllib.request

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda

logger = logging.getLogger("agenda_lambda")
logger.setLevel(logging.INFO)

AuthUser = namedtuple("AuthUser", ["sub", "email"])

_JWKS_CACHE = None
_JWKS_CACHE_TIME = 0.0


def _get_jwks(issuer: str):
    global _JWKS_CACHE, _JWKS_CACHE_TIME
    import jwt
    now = time.monotonic()
    if _JWKS_CACHE is not None and (now - _JWKS_CACHE_TIME) < 300:
        return _JWKS_CACHE

    url = f"{issuer}/.well-known/jwks.json"
    with urllib.request.urlopen(url, timeout=5) as response:
        _JWKS_CACHE = jwt.PyJWKSet.from_json(response.read().decode("utf-8"))
        _JWKS_CACHE_TIME = now
        return _JWKS_CACHE


def verify_cognito_token(auth_header: str) -> AuthUser:
    if not auth_header or not auth_header.startswith("Bearer "):
        raise ValueError("Missing or invalid Authorization header")

    token = auth_header.split(" ", 1)[1].strip()
    user_pool_id = os.environ.get("COGNITO_USER_POOL_ID", "")
    client_id = os.environ.get("COGNITO_CLIENT_ID", "")
    region = os.environ.get("AWS_REGION", "us-east-1")

    if not user_pool_id or not client_id:
        # If running in test mode without Cognito configured
        return AuthUser(sub="anonymous-user", email="")

    issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
    jwks = _get_jwks(issuer)

    import jwt

    kid = jwt.get_unverified_header(token).get("kid")
    key = next((k for k in jwks.keys if k.key_id == kid), None)
    if not key:
        raise ValueError("Unknown signing key id")

    claims = jwt.decode(
        token,
        key.key,
        algorithms=["RS256"],
        audience=client_id,
        issuer=issuer,
        options={"require": ["exp", "iat", "sub", "aud", "iss"]},
    )

    if claims.get("token_use") != "id":
        raise ValueError("Not an ID token")

    return AuthUser(sub=claims["sub"], email=claims.get("email", ""))


def handler(event, context):
    """AWS Lambda entry point for agenda parsing."""
    headers = event.get("headers") or {}
    # Case-insensitive header lookup
    auth_header = headers.get("authorization") or headers.get("Authorization") or ""

    resp_headers = {
        "Content-Type": "application/json",
    }

    # Handle CORS preflight
    http_method = (
        event.get("requestContext", {}).get("http", {}).get("method")
        or event.get("httpMethod")
        or ""
    ).upper()
    if http_method == "OPTIONS":
        return {"statusCode": 200, "headers": resp_headers, "body": "{}"}

    try:
        user = verify_cognito_token(auth_header)
    except Exception as e:
        logger.warning("Authentication failed: %s", e)
        return {
            "statusCode": 401,
            "headers": resp_headers,
            "body": json.dumps({"error": "Unauthorized"}),
        }

    raw_body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        import base64
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    try:
        body = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
    except Exception as e:
        return {
            "statusCode": 400,
            "headers": resp_headers,
            "body": json.dumps({"error": f"Invalid JSON body: {e}"}),
        }

    text = body.get("text", "")
    if len(text) > 10000:
        return {
            "statusCode": 413,
            "headers": resp_headers,
            "body": json.dumps({"error": "Text too long (max 10,000 characters)"}),
        }

    try:
        today_val = date.fromisoformat(body["today"]) if "today" in body else date.today()
    except Exception:
        today_val = date.today()

    tz = body.get("tz", "Europe/Kyiv")
    model = os.environ.get("PARSER_MODEL", "anthropic.claude-opus-5-5")

    started = time.monotonic()
    try:
        agenda, usage = parse_agenda(text, today=today_val, tz=tz, model=model)
    except AgendaParseError as e:
        logger.warning("Agenda parse error: %s", e)
        return {
            "statusCode": 422,
            "headers": resp_headers,
            "body": json.dumps({"error": str(e)}),
        }
    except Exception as e:
        err_msg = str(e)
        if "ThrottlingException" in err_msg or "429" in err_msg:
            return {
                "statusCode": 429,
                "headers": resp_headers,
                "body": json.dumps({"error": "Bedrock is currently busy. Please try again shortly."}),
            }
        logger.exception("Unexpected error during parsing: %s", e)
        return {
            "statusCode": 500,
            "headers": resp_headers,
            "body": json.dumps({"error": f"Server error: {err_msg}"}),
        }

    latency_ms = int((time.monotonic() - started) * 1000)
    calculated_cost = cost_usd(model, usage)

    log_entry = {
        "event": "agenda_parsed",
        "user": user.sub,
        "model": model,
        "prompt_version": PROMPT_VERSION,
        **usage,
        "latency_ms": latency_ms,
        "cost_usd": calculated_cost,
    }
    logger.info(json.dumps(log_entry))

    return {
        "statusCode": 200,
        "headers": resp_headers,
        "body": json.dumps(
            {
                "agenda": agenda.model_dump(mode="json"),
                "model": model,
                "prompt_version": PROMPT_VERSION,
            }
        ),
    }

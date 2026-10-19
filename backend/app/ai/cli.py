"""CLI for Bedrock LLM checks and parsing."""

import argparse
import json
import os
import sys
from datetime import date

from app.ai.agenda import cost_usd, parse_agenda


def hello():
    model = os.environ.get("PARSER_MODEL", "anthropic.claude-opus-5-5")
    region = os.environ.get("AWS_REGION", "us-east-1")
    prompt = "In one sentence: what is an ISO week?"

    if model.startswith("anthropic."):
        try:
            from anthropic import AnthropicBedrockMantle

            client = AnthropicBedrockMantle(aws_region=region)
            kwargs = {
                "model": model,
                "max_tokens": 1024,
                "messages": [{"role": "user", "content": prompt}],
            }
            if "opus" in model:
                kwargs["output_config"] = {"effort": "low"}
            msg = client.messages.create(**kwargs)
            text = next(b.text for b in msg.content if b.type == "text")
            print(text)
            print(f"stop_reason: {msg.stop_reason}, input_tokens: {msg.usage.input_tokens}, output_tokens: {msg.usage.output_tokens}")
            return
        except Exception as e:
            print(f"AnthropicBedrockMantle failed ({e}), falling back to Converse API...", file=sys.stderr)

    import boto3

    brt = boto3.client("bedrock-runtime", region_name=region)
    resp = brt.converse(
        modelId=model,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 200},
    )
    print(resp["output"]["message"]["content"][0]["text"])
    usage = resp.get("usage", {})
    print(f"stop_reason: {resp.get('stopReason')}, input_tokens: {usage.get('inputTokens')}, output_tokens: {usage.get('outputTokens')}")


def parse(text: str, model: str | None = None, tz: str = "Europe/Kyiv"):
    today = date.today()
    active_model = model or os.environ.get("PARSER_MODEL", "anthropic.claude-opus-5-5")
    agenda, usage = parse_agenda(text, today=today, tz=tz, model=active_model)
    res = {
        "agenda": agenda.model_dump(mode="json"),
        "usage": usage,
        "cost_usd": cost_usd(active_model, usage),
        "model": active_model,
    }
    print(json.dumps(res, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="Bedrock LLM CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("hello", help="Run LLM hello check")

    parse_cmd = subparsers.add_parser("parse", help="Parse agenda text")
    parse_cmd.add_argument("text", help="Pasted agenda text")
    parse_cmd.add_argument("--model", default=None, help="Model override")
    parse_cmd.add_argument("--tz", default="Europe/Kyiv", help="Timezone")

    args = parser.parse_args()
    if args.command == "hello":
        hello()
    elif args.command == "parse":
        parse(args.text, model=args.model, tz=args.tz)


if __name__ == "__main__":
    main()

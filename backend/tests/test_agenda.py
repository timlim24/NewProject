from datetime import date
from unittest.mock import patch
import json

from app.ai.agenda import ActionItem, AgendaItem, AgendaParseError, ParsedAgenda, cost_usd
from app.ai.agenda_lambda import handler


def test_agenda_models():
    item = AgendaItem(topic="New Pro tariffs", owner="Olena", minutes=15)
    assert item.topic == "New Pro tariffs"
    assert item.owner == "Olena"
    assert item.minutes == 15

    action = ActionItem(task="Competitor comparison", owner="Taras", due=date(2026, 10, 23))
    assert action.task == "Competitor comparison"
    assert action.due == date(2026, 10, 23)

    agenda = ParsedAgenda(
        title="Pricing Sync",
        starts_at="2026-10-19T10:00:00+03:00",
        duration_minutes=45,
        items=[item],
        action_items=[action],
        language="uk",
    )
    dumped = agenda.model_dump(mode="json")
    assert dumped["title"] == "Pricing Sync"
    assert len(dumped["items"]) == 1
    assert len(dumped["action_items"]) == 1
    assert dumped["action_items"][0]["due"] == "2026-10-23"


def test_cost_usd_calculation():
    usage = {"input_tokens": 1000, "output_tokens": 200}
    # Opus: 1000 * 4/1M + 200 * 20/1M = 0.004 + 0.004 = 0.008
    cost_opus = cost_usd("anthropic.claude-opus-5-5", usage)
    assert cost_opus == 0.008

    # Haiku: 1000 * 0.1/1M + 200 * 0.5/1M = 0.0001 + 0.0001 = 0.0002
    cost_haiku = cost_usd("anthropic.claude-haiku-5-5", usage)
    assert cost_haiku == 0.0002


def test_lambda_options_preflight():
    event = {
        "requestContext": {"http": {"method": "OPTIONS"}},
        "headers": {},
    }
    resp = handler(event, None)
    assert resp["statusCode"] == 200
    assert "Access-Control-Allow-Origin" in resp["headers"]


def test_lambda_unauthorized_without_token():
    event = {
        "headers": {},
        "body": json.dumps({"text": "meeting notes"}),
    }
    resp = handler(event, None)
    assert resp["statusCode"] == 401


def test_lambda_text_too_long():
    with patch("app.ai.agenda_lambda.verify_cognito_token") as mock_auth:
        from collections import namedtuple
        AuthUser = namedtuple("AuthUser", ["sub", "email"])
        mock_auth.return_value = AuthUser(sub="user-123", email="user@example.com")

        event = {
            "headers": {"authorization": "Bearer dummy-token"},
            "body": json.dumps({"text": "a" * 10001, "today": "2026-10-19"}),
        }
        resp = handler(event, None)
        assert resp["statusCode"] == 413
        assert "Text too long" in resp["body"]


def test_lambda_successful_parse():
    with patch("app.ai.agenda_lambda.verify_cognito_token") as mock_auth, \
         patch("app.ai.agenda_lambda.parse_agenda") as mock_parse:
        from collections import namedtuple
        AuthUser = namedtuple("AuthUser", ["sub", "email"])
        mock_auth.return_value = AuthUser(sub="user-123", email="user@example.com")

        mock_agenda = ParsedAgenda(
            title="Pricing Sync",
            items=[AgendaItem(topic="Tariffs", owner="Olena", minutes=15)],
            language="uk",
        )
        mock_parse.return_value = (mock_agenda, {"input_tokens": 120, "output_tokens": 40})

        event = {
            "headers": {"authorization": "Bearer valid-token"},
            "body": json.dumps({
                "text": "Пн 10:00, синк по прайсингу. 1) нові тарифи Pro — Олена, 15 хв",
                "today": "2026-10-19",
                "tz": "Europe/Kyiv",
            }),
        }
        resp = handler(event, None)
        assert resp["statusCode"] == 200
        data = json.loads(resp["body"])
        assert data["agenda"]["title"] == "Pricing Sync"
        assert data["agenda"]["items"][0]["owner"] == "Olena"

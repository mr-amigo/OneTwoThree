import uuid
from datetime import datetime

from fastapi.testclient import TestClient


def create_participant(client: TestClient, name: str, email: str) -> dict:
    response = client.post("/api/participants", json={"name": name, "email": email})
    assert response.status_code == 201, response.text
    return response.json()


def meeting_payload(**overrides) -> dict:
    payload = {
        "title": "Sprint planning",
        "description": "Plan sprint 12 scope",
        "call_link": "https://meet.google.com/abc-defg-hij",
        "place": "Room 204",
        "starts_at": "2026-09-28T10:00:00+03:00",
        "ends_at": "2026-09-28T11:00:00+03:00",
        "participant_ids": [],
    }
    payload.update(overrides)
    return payload


def test_health(client: TestClient):
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_create_list_and_delete_meeting(client: TestClient):
    anna = create_participant(client, "Anna", "anna@example.com")
    oleh = create_participant(client, "Oleh", "oleh@example.com")

    response = client.post("/api/meetings", json=meeting_payload(participant_ids=[anna["id"], oleh["id"]]))
    assert response.status_code == 201, response.text
    meeting = response.json()
    uuid.UUID(meeting["id"])
    assert datetime.fromisoformat(meeting["starts_at"]) == datetime.fromisoformat("2026-09-28T07:00:00Z")
    assert datetime.fromisoformat(meeting["ends_at"]) == datetime.fromisoformat("2026-09-28T08:00:00Z")
    assert [p["name"] for p in meeting["participants"]] == ["Anna", "Oleh"]

    listed = client.get("/api/meetings").json()
    assert [m["id"] for m in listed] == [meeting["id"]]

    assert client.delete(f"/api/meetings/{meeting['id']}").status_code == 204
    assert client.get("/api/meetings").json() == []
    assert client.get(f"/api/meetings/{meeting['id']}").status_code == 404


def test_update_meeting(client: TestClient):
    anna = create_participant(client, "Anna", "anna@example.com")
    oleh = create_participant(client, "Oleh", "oleh@example.com")
    meeting = client.post("/api/meetings", json=meeting_payload(participant_ids=[anna["id"]])).json()

    response = client.put(
        f"/api/meetings/{meeting['id']}",
        json=meeting_payload(
            title="Sprint review",
            call_link=None,
            starts_at="2026-09-29T14:00:00Z",
            ends_at="2026-09-29T15:30:00Z",
            participant_ids=[oleh["id"]],
        ),
    )
    assert response.status_code == 200, response.text
    updated = response.json()
    assert updated["id"] == meeting["id"]
    assert updated["title"] == "Sprint review"
    assert updated["call_link"] is None
    assert datetime.fromisoformat(updated["ends_at"]) == datetime.fromisoformat("2026-09-29T15:30:00Z")
    assert [p["name"] for p in updated["participants"]] == ["Oleh"]
    assert client.get(f"/api/meetings/{meeting['id']}").json() == updated


def test_update_validates_and_checks_existence(client: TestClient):
    meeting = client.post("/api/meetings", json=meeting_payload()).json()
    assert client.put(f"/api/meetings/{meeting['id']}", json=meeting_payload(title="")).status_code == 422
    assert client.put(f"/api/meetings/{uuid.uuid4()}", json=meeting_payload()).status_code == 404
    missing = str(uuid.uuid4())
    response = client.put(f"/api/meetings/{meeting['id']}", json=meeting_payload(participant_ids=[missing]))
    assert response.status_code == 404


def test_meetings_are_listed_by_start_time(client: TestClient):
    for title, start, end in (
        ("Retro", "2026-09-30T15:00:00Z", "2026-09-30T16:00:00Z"),
        ("Standup", "2026-09-28T09:00:00Z", "2026-09-28T09:15:00Z"),
    ):
        response = client.post(
            "/api/meetings", json=meeting_payload(title=title, starts_at=start, ends_at=end)
        )
        assert response.status_code == 201, response.text

    assert [m["title"] for m in client.get("/api/meetings").json()] == ["Standup", "Retro"]


def test_participant_can_join_many_meetings(client: TestClient):
    anna = create_participant(client, "Anna", "anna@example.com")
    for title in ("Standup", "Retro"):
        response = client.post(
            "/api/meetings", json=meeting_payload(title=title, participant_ids=[anna["id"]])
        )
        assert response.status_code == 201

    meetings = client.get("/api/meetings").json()
    assert len(meetings) == 2
    assert all(m["participants"][0]["id"] == anna["id"] for m in meetings)


def test_deleting_meeting_keeps_participants(client: TestClient):
    anna = create_participant(client, "Anna", "anna@example.com")
    meeting = client.post("/api/meetings", json=meeting_payload(participant_ids=[anna["id"]])).json()

    client.delete(f"/api/meetings/{meeting['id']}")

    assert [p["id"] for p in client.get("/api/participants").json()] == [anna["id"]]


def test_duplicate_participant_ids_are_deduplicated(client: TestClient):
    anna = create_participant(client, "Anna", "anna@example.com")
    response = client.post("/api/meetings", json=meeting_payload(participant_ids=[anna["id"], anna["id"]]))
    assert response.status_code == 201
    assert len(response.json()["participants"]) == 1


def test_empty_title_is_rejected(client: TestClient):
    response = client.post("/api/meetings", json=meeting_payload(title="   "))
    assert response.status_code == 422


def test_bad_call_link_is_rejected(client: TestClient):
    response = client.post("/api/meetings", json=meeting_payload(call_link="not a url"))
    assert response.status_code == 422


def test_call_link_or_place_is_required(client: TestClient):
    response = client.post("/api/meetings", json=meeting_payload(call_link=None, place=""))
    assert response.status_code == 422


def test_meeting_must_end_after_it_starts(client: TestClient):
    response = client.post(
        "/api/meetings",
        json=meeting_payload(starts_at="2026-09-28T10:00:00Z", ends_at="2026-09-28T10:00:00Z"),
    )
    assert response.status_code == 422


def test_meeting_time_needs_a_timezone(client: TestClient):
    response = client.post("/api/meetings", json=meeting_payload(starts_at="2026-09-28T10:00:00"))
    assert response.status_code == 422


def test_unknown_participant_returns_404(client: TestClient):
    missing = str(uuid.uuid4())
    response = client.post("/api/meetings", json=meeting_payload(participant_ids=[missing]))
    assert response.status_code == 404
    assert missing in response.json()["detail"]


def test_malformed_uuid_returns_422(client: TestClient):
    assert client.get("/api/meetings/not-a-uuid").status_code == 422
    assert client.delete("/api/meetings/123").status_code == 422


def test_delete_unknown_meeting_returns_404(client: TestClient):
    assert client.delete(f"/api/meetings/{uuid.uuid4()}").status_code == 404


def test_duplicate_participant_email_returns_409(client: TestClient):
    create_participant(client, "Anna", "anna@example.com")
    response = client.post("/api/participants", json={"name": "Anna 2", "email": "ANNA@example.com"})
    assert response.status_code == 409


def test_participant_search(client: TestClient):
    create_participant(client, "Anna", "anna@example.com")
    create_participant(client, "Oleh", "oleh@example.com")
    names = [p["name"] for p in client.get("/api/participants", params={"q": "ole"}).json()]
    assert names == ["Oleh"]


def _agenda_body(minutes: int = 15) -> dict:
    suggested = {"items": [{"topic": "Pricing", "owner": "Olena", "minutes": 15}], "language": "en"}
    return {
        "agenda_items": [{"topic": "Pricing", "owner": "Olena", "minutes": minutes}],
        "action_items": [{"task": "Compare competitors", "owner": "Taras", "due": "2026-10-30"}],
        "ai_suggestion": {
            "agenda": suggested,
            "model": "anthropic.claude-opus-5-5",
            "prompt_version": "agenda-v1",
        },
    }


def test_meeting_starts_without_an_agenda(client: TestClient):
    meeting = client.post("/api/meetings", json=meeting_payload()).json()
    assert meeting["agenda_items"] == [] and meeting["ai_suggestion"] is None


def test_agenda_is_saved_with_the_suggestion_it_started_from(client: TestClient):
    meeting = client.post("/api/meetings", json=meeting_payload()).json()
    resp = client.put(f"/api/meetings/{meeting['id']}/agenda", json=_agenda_body(minutes=20))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["agenda_items"][0]["minutes"] == 20  # what the user saved
    assert body["ai_suggestion"]["agenda"]["items"][0]["minutes"] == 15  # what the model suggested
    assert body["action_items"][0]["due"] == "2026-10-30"
    assert client.get(f"/api/meetings/{meeting['id']}").json()["agenda_items"] == body["agenda_items"]


def test_editing_a_meeting_keeps_its_agenda(client: TestClient):
    meeting = client.post("/api/meetings", json=meeting_payload()).json()
    client.put(f"/api/meetings/{meeting['id']}/agenda", json=_agenda_body())
    edited = client.put(f"/api/meetings/{meeting['id']}", json=meeting_payload(title="Renamed")).json()
    assert edited["title"] == "Renamed" and len(edited["agenda_items"]) == 1


def test_invalid_agenda_is_rejected(client: TestClient):
    meeting = client.post("/api/meetings", json=meeting_payload()).json()
    url = f"/api/meetings/{meeting['id']}/agenda"
    assert client.put(url, json={"agenda_items": [{"topic": ""}]}).status_code == 422
    assert client.put(url, json={"agenda_items": [{"topic": "x", "minutes": 481}]}).status_code == 422


def test_agenda_of_unknown_meeting_returns_404(client: TestClient):
    assert client.put(f"/api/meetings/{uuid.uuid4()}/agenda", json={}).status_code == 404

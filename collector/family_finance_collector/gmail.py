from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from .config import GmailSettings
from .rules import MailEnvelope

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]


@dataclass(frozen=True)
class GmailBatch:
    envelopes: tuple[MailEnvelope, ...]
    history_id: str
    full_sync: bool


def _header(message: dict[str, Any], name: str) -> str:
    headers = message.get("payload", {}).get("headers", [])
    target = name.casefold()
    for header in headers:
        if str(header.get("name", "")).casefold() == target:
            return str(header.get("value", ""))
    return ""


def _envelope(message: dict[str, Any]) -> MailEnvelope:
    return MailEnvelope(
        message_id=str(message["id"]),
        internal_date_ms=int(message.get("internalDate") or 0),
        sender=_header(message, "From"),
        subject=_header(message, "Subject"),
        snippet=str(message.get("snippet", "")),
    )


class GmailClient:
    def __init__(self, token_file: str | Path) -> None:
        credentials = Credentials.from_authorized_user_file(str(token_file), SCOPES)
        self.service = build("gmail", "v1", credentials=credentials, cache_discovery=False)

    def _get_messages(self, user_id: str, message_ids: Iterable[str]) -> tuple[MailEnvelope, ...]:
        result: list[MailEnvelope] = []
        for message_id in dict.fromkeys(message_ids):
            message = (
                self.service.users()
                .messages()
                .get(
                    userId=user_id,
                    id=message_id,
                    format="metadata",
                    metadataHeaders=["From", "Subject"],
                )
                .execute()
            )
            result.append(_envelope(message))
        return tuple(result)

    def full_sync(self, settings: GmailSettings) -> GmailBatch:
        ids: list[str] = []
        page_token: str | None = None
        while len(ids) < settings.max_initial_messages:
            kwargs: dict[str, Any] = {
                "userId": settings.user_id,
                "q": settings.initial_query,
                "maxResults": min(500, settings.max_initial_messages - len(ids)),
            }
            if page_token:
                kwargs["pageToken"] = page_token
            response = self.service.users().messages().list(**kwargs).execute()
            ids.extend(str(item["id"]) for item in response.get("messages", []))
            page_token = response.get("nextPageToken")
            if not page_token:
                break
        profile = self.service.users().getProfile(userId=settings.user_id).execute()
        return GmailBatch(
            envelopes=self._get_messages(settings.user_id, ids[: settings.max_initial_messages]),
            history_id=str(profile["historyId"]),
            full_sync=True,
        )

    def incremental_sync(self, settings: GmailSettings, history_id: str) -> GmailBatch:
        ids: list[str] = []
        page_token: str | None = None
        latest_history_id = history_id
        try:
            while True:
                kwargs: dict[str, Any] = {
                    "userId": settings.user_id,
                    "startHistoryId": history_id,
                    "historyTypes": ["messageAdded"],
                    "maxResults": 500,
                }
                if page_token:
                    kwargs["pageToken"] = page_token
                response = self.service.users().history().list(**kwargs).execute()
                latest_history_id = str(response.get("historyId", latest_history_id))
                for history in response.get("history", []):
                    for added in history.get("messagesAdded", []):
                        message = added.get("message") or {}
                        if "id" in message:
                            ids.append(str(message["id"]))
                page_token = response.get("nextPageToken")
                if not page_token:
                    break
        except HttpError as exc:
            if getattr(exc.resp, "status", None) == 404:
                return self.full_sync(settings)
            raise
        return GmailBatch(
            envelopes=self._get_messages(settings.user_id, ids),
            history_id=latest_history_id,
            full_sync=False,
        )

    def collect(self, settings: GmailSettings, cursor: dict[str, Any]) -> GmailBatch:
        history_id = cursor.get("history_id")
        if isinstance(history_id, str) and history_id:
            return self.incremental_sync(settings, history_id)
        return self.full_sync(settings)

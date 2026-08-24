from __future__ import annotations

import io
from dataclasses import dataclass
from pathlib import Path

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

from .config import DriveAppDataSettings
from .device_relay import parse_notification_batch
from .rules import Observation

APPDATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"


@dataclass(frozen=True)
class DrivePollResult:
    observations: tuple[Observation, ...]
    processed_file_ids: tuple[str, ...]
    files_seen: int


class DriveAppDataClient:
    def __init__(self, token_file: Path) -> None:
        credentials = Credentials.from_authorized_user_file(
            str(token_file), scopes=[APPDATA_SCOPE]
        )
        self.service = build("drive", "v3", credentials=credentials, cache_discovery=False)

    def _download(self, file_id: str) -> bytes:
        buffer = io.BytesIO()
        request = self.service.files().get_media(fileId=file_id)
        downloader = MediaIoBaseDownload(buffer, request, chunksize=256 * 1024)
        done = False
        while not done:
            _, done = downloader.next_chunk()
        return buffer.getvalue()

    def collect(self, settings: DriveAppDataSettings) -> DrivePollResult:
        response = self.service.files().list(
            spaces="appDataFolder",
            q="'appDataFolder' in parents and trashed = false",
            orderBy="createdTime asc",
            pageSize=settings.max_files_per_cycle,
            fields="files(id,name,createdTime,size)",
        ).execute()
        files = response.get("files", [])
        if not isinstance(files, list):
            raise RuntimeError("unexpected Drive files response")

        observations: list[Observation] = []
        processed: list[str] = []
        matched = 0
        for item in files:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", ""))
            file_id = str(item.get("id", ""))
            if not file_id or not name.startswith(settings.file_prefix):
                continue
            matched += 1
            observations.extend(parse_notification_batch(self._download(file_id)))
            processed.append(file_id)

        return DrivePollResult(
            observations=tuple(observations),
            processed_file_ids=tuple(processed),
            files_seen=matched,
        )

    def acknowledge(self, file_ids: tuple[str, ...]) -> None:
        for file_id in file_ids:
            self.service.files().delete(fileId=file_id).execute()

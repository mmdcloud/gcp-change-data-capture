"""Error-archive handler: Pub/Sub push -> BigQuery.

Receives Cloud Logging entries (routed by the log sink to the error topic via a
Pub/Sub PUSH subscription) and writes one row per entry to BigQuery.

Return codes matter, because Pub/Sub retries on anything that is not 2xx:
  204  stored, or the message can never be processed (retrying is pointless)
  500  transient/BigQuery failure -> Pub/Sub retries, then dead-letters after
       max_delivery_attempts
"""

import base64
import binascii
import datetime
import json
import logging
import os
import re

import functions_framework
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Fail fast at cold start if misconfigured.
TABLE_ID = "{}.{}.{}".format(
    os.environ["BQ_PROJECT"],
    os.environ["BQ_DATASET"],
    os.environ.get("BQ_TABLE", "datastream_failed_events"),
)
MAX_PAYLOAD_CHARS = 100_000

bq_client = bigquery.Client()

# Cloud Logging timestamps carry nanoseconds; BigQuery TIMESTAMP stops at micros.
_FRACTION = re.compile(r"(\.\d{6})\d+")


def _as_dict(value):
    return value if isinstance(value, dict) else {}


def _timestamp(entry):
    ts = entry.get("timestamp") or entry.get("receiveTimestamp")
    if not isinstance(ts, str) or not ts:
        return datetime.datetime.now(datetime.timezone.utc).isoformat()
    return _FRACTION.sub(r"\1", ts)


def _error_message(entry):
    if entry.get("textPayload"):
        return str(entry["textPayload"])
    json_payload = _as_dict(entry.get("jsonPayload"))
    if json_payload:
        return str(json_payload.get("message") or json.dumps(json_payload))
    status = _as_dict(_as_dict(entry.get("protoPayload")).get("status"))
    if status.get("message"):
        return str(status["message"])
    return json.dumps(entry.get("protoPayload") or {})


@functions_framework.http
def handle_dlq_event(request):
    envelope = request.get_json(silent=True)
    if not isinstance(envelope, dict) or not isinstance(envelope.get("message"), dict):
        # Not a Pub/Sub push body; retrying cannot fix that.
        logger.error("Request is not a Pub/Sub push envelope; dropping")
        return ("", 204)

    message = envelope["message"]
    encoded = message.get("data", "")

    try:
        raw = base64.b64decode(encoded, validate=True).decode("utf-8")
        entry = json.loads(raw)
        if not isinstance(entry, dict):
            raise ValueError("log entry is not a JSON object")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        # Keep whatever we got so nothing is silently lost.
        raw = encoded if isinstance(encoded, str) else json.dumps(encoded)
        entry = {"textPayload": "unparseable payload: " + raw[:1000]}

    labels = _as_dict(_as_dict(entry.get("resource")).get("labels"))
    row = {
        "timestamp": _timestamp(entry),
        "stream_id": labels.get("stream_id", "unknown"),
        "log_name": entry.get("logName", ""),
        "severity": entry.get("severity", "ERROR"),
        "error_message": _error_message(entry),
        "raw_payload": raw[:MAX_PAYLOAD_CHARS],
    }

    # Best-effort dedupe: BigQuery drops repeats of the same row id within ~1 minute.
    row_id = entry.get("insertId") or message.get("messageId")

    try:
        errors = bq_client.insert_rows_json(TABLE_ID, [row], row_ids=[row_id])
    except Exception:  # network/API failure -> let Pub/Sub retry
        logger.exception("BigQuery insert raised for %s", row_id)
        return ("BigQuery insert failed", 500)

    if errors:
        # Row-level rejection (e.g. schema drift). Retry a few times, then the
        # subscription dead-letters it so a human can look.
        logger.error("BigQuery rejected row %s: %s", row_id, errors)
        return ("BigQuery rejected row", 500)

    return ("", 204)
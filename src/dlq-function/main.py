import base64
import datetime
import json
import os
import functions_framework
from google.cloud import bigquery

bq_client = bigquery.Client()

@functions_framework.cloud_event
def handle_dlq_event(cloud_event):
    """Handles Pub/Sub Dead-Letter Queue events and writes error logs to BigQuery."""
    pubsub_data = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")

    try:
        payload = json.loads(pubsub_data)
    except Exception:
        payload = {"textPayload": pubsub_data}

    if isinstance(payload, dict):
        stream_id = payload.get("resource", {}).get("labels", {}).get("stream_id", "unknown")
        log_name = payload.get("logName", "")
        severity = payload.get("severity", "ERROR")
        error_message = payload.get("textPayload") or json.dumps(payload.get("jsonPayload", {}))
    else:
        stream_id = "unknown"
        log_name = ""
        severity = "ERROR"
        error_message = str(pubsub_data)

    row = [{
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "stream_id": stream_id,
        "log_name": log_name,
        "severity": severity,
        "error_message": error_message,
        "raw_payload": pubsub_data
    }]

    project = os.environ.get("BQ_PROJECT")
    dataset = os.environ.get("BQ_DATASET")
    table = os.environ.get("BQ_TABLE", "datastream_failed_events")
    table_id = f"{project}.{dataset}.{table}"

    errors = bq_client.insert_rows_json(table_id, row)
    if errors:
        raise RuntimeError(f"Failed to insert rows into BigQuery: {errors}")
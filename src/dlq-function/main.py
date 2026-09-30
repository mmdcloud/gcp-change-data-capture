# The Cloud Run Function subscribes directly to google_pubsub_topic.datastream_dlq
# Python handler snippet:

from google.cloud import bigquery
import base64, json, datetime

bq_client = bigquery.Client()

def handle_dlq_event(cloud_event):
    pubsub_data = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
    payload = json.loads(pubsub_data)

    row = [{
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "stream_id": payload.get("resource", {}).get("labels", {}).get("stream_id", "unknown"),
        "log_name": payload.get("logName", ""),
        "severity": payload.get("severity", "ERROR"),
        "error_message": payload.get("textPayload") or json.dumps(payload.get("jsonPayload", {})),
        "raw_payload": pubsub_data
    }]
    bq_client.insert_rows_json("var.project_id.${google_bigquery_dataset.dlq_dataset.dataset_id}.${google_bigquery_table.datastream_dlq_events.table_id}", row)
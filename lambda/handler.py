"""
Cloud Log Analytics — AWS Lambda Anomaly Detector (Isolation Forest)
===================================================================
Runs every 5 minutes via AWS EventBridge.
Ingests recent CloudWatch log events, groups into 30-second time buckets per service,
extracts 4-dimensional feature vectors (volume, error rate, warn rate, avg latency),
runs scikit-learn IsolationForest, persists anomalies to RDS, and alerts via SNS.

Author: Ankit Kumar Mishra (M.Tech CS, Delhi Technological University)
"""

from __future__ import annotations

import json
import logging
import os
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Optional

import numpy as np
try:
    from sklearn.ensemble import IsolationForest
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    IsolationForest = None

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────
DB_SECRET_ARN  = os.environ.get("DB_SECRET_ARN", "")
SNS_TOPIC_ARN  = os.environ.get("SNS_TOPIC_ARN", "")
LOG_GROUP_NAME = os.environ.get("LOG_GROUP_NAME", "/aws/cloud-log-analytics/app")
ENVIRONMENT    = os.environ.get("ENVIRONMENT", "production")
WINDOW_MINUTES = int(os.environ.get("WINDOW_MINUTES", "5"))
CONTAMINATION  = float(os.environ.get("CONTAMINATION", "0.05"))

SEVERITY_THRESHOLDS = {
    "CRITICAL": -0.70,
    "HIGH":     -0.50,
    "MEDIUM":   -0.30,
    "LOW":      -0.10,
}

# ─────────────────────────────────────────────────────────
# Database Connection (AWS Secrets Manager)
# ─────────────────────────────────────────────────────────
def get_db_conn():
    """Retrieve RDS credentials from AWS Secrets Manager and establish connection."""
    import boto3
    import psycopg2
    sm_client = boto3.client("secretsmanager")
    secret_val = sm_client.get_secret_value(SecretId=DB_SECRET_ARN)["SecretString"]
    secret = json.loads(secret_val)
    return psycopg2.connect(
        host=secret["host"],
        port=secret.get("port", 5432),
        dbname=secret.get("dbname", "loganalytics"),
        user=secret["username"],
        password=secret["password"],
        connect_timeout=10,
        sslmode="require",
    )

# ─────────────────────────────────────────────────────────
# Feature Engineering & Time Bucket Aggregation
# ─────────────────────────────────────────────────────────
def parse_log_line(message: str) -> dict[str, Any]:
    """Parse JSON or key=value formatted log lines into structured dictionaries."""
    try:
        return json.loads(message)
    except (json.JSONDecodeError, TypeError):
        pass

    parts: dict[str, Any] = {"raw": message}
    for part in message.split():
        if "=" in part:
            k, _, v = part.partition("=")
            parts[k.strip()] = v.strip().strip('"').strip("'")
    return parts

def build_time_buckets(events: list[dict], bucket_seconds: int = 30) -> dict[str, dict[int, dict]]:
    """
    Groups raw log events into 30-second time buckets per service.
    Aggregates: total events, error count, warn count, total latency.
    """
    buckets: dict[str, dict[int, dict]] = defaultdict(lambda: defaultdict(
        lambda: {"total": 0, "errors": 0, "warns": 0, "total_latency": 0, "count_latency": 0}
    ))

    for ev in events:
        raw_ts = ev.get("timestamp")
        if raw_ts is None:
            continue
        ts_s = raw_ts // 1000 if raw_ts > 10_000_000_000 else int(raw_ts)
        bucket = (ts_s // bucket_seconds) * bucket_seconds

        msg = ev.get("message", "")
        parsed = parse_log_line(msg) if isinstance(msg, str) else ev

        service = parsed.get("service") or ev.get("service", "unknown")
        service = str(service).lower().strip()

        level = str(parsed.get("level") or ev.get("level", "INFO")).upper()
        latency = parsed.get("latency_ms") or parsed.get("lat_ms") or ev.get("latency_ms")

        b = buckets[service][bucket]
        b["total"] += 1
        if level in ("ERROR", "FATAL"):
            b["errors"] += 1
        elif level == "WARN":
            b["warns"] += 1

        if latency is not None:
            try:
                b["total_latency"] += int(latency)
                b["count_latency"] += 1
            except (ValueError, TypeError):
                pass

    return buckets

def extract_feature_matrix(service_buckets: dict[int, dict]) -> tuple[np.ndarray, list[int]]:
    """
    Extracts 4-dimensional feature vector per time bucket:
    [total_events, error_rate, warn_rate, avg_latency]
    """
    rows = []
    keys = sorted(service_buckets.keys())
    for k in keys:
        b = service_buckets[k]
        total = b["total"]
        error_rate = b["errors"] / max(total, 1)
        warn_rate = b["warns"] / max(total, 1)
        avg_latency = (b["total_latency"] / b["count_latency"]) if b["count_latency"] > 0 else 0.0
        rows.append([float(total), float(error_rate), float(warn_rate), float(avg_latency)])
    return np.array(rows, dtype=float), keys

# ─────────────────────────────────────────────────────────
# Isolation Forest Anomaly Detection
# ─────────────────────────────────────────────────────────
def score_to_severity(score: float) -> str:
    """Maps continuous anomaly score depth to discrete severity tier."""
    for sev, threshold in SEVERITY_THRESHOLDS.items():
        if score <= threshold:
            return sev
    return "LOW"

def _build_description(service: str, features: np.ndarray, score: float) -> str:
    total, err_rate, warn_rate, avg_lat = features
    parts = [f"Anomaly in {service}:"]
    if err_rate >= 0.1:
        parts.append(f"error rate {err_rate*100:.1f}%")
    if warn_rate >= 0.2:
        parts.append(f"warn rate {warn_rate*100:.1f}%")
    if avg_lat >= 500:
        parts.append(f"avg latency {avg_lat:.0f}ms")
    if int(total) >= 30:
        parts.append(f"volume spike {int(total)} events")
    parts.append(f"(score={abs(score):.3f})")
    return " | ".join(parts)

def detect_anomalies(service: str, X: np.ndarray, bucket_keys: list[int]) -> list[dict]:
    """
    Fits IsolationForest to partition feature space.
    Anomalous points separated in fewer splits receive a lower (negative) score.
    """
    if len(X) < 4:
        logger.info("Not enough buckets for %s (%d) — skipping", service, len(X))
        return []

    if not HAS_SKLEARN:
        # Statistical Z-score outlier fallback when scikit-learn is not available in local test env
        err_rates = X[:, 1]
        latencies = X[:, 3]
        mean_err, std_err = float(np.mean(err_rates)), float(np.std(err_rates)) or 1.0
        mean_lat, std_lat = float(np.mean(latencies)), float(np.std(latencies)) or 1.0
        z_scores = ((err_rates - mean_err) / std_err) + ((latencies - mean_lat) / std_lat)
        predictions = np.where(z_scores > 2.0, -1, 1)
        raw_scores = -0.4 - (z_scores * 0.15)
    else:
        clf = IsolationForest(
            n_estimators=100,
            contamination=CONTAMINATION,
            random_state=42,
        )
        clf.fit(X)
        raw_scores = clf.score_samples(X)   # Negated average anomaly depth
        predictions = clf.predict(X)        # -1 = anomaly, 1 = normal

    anomalies = []
    for i, (pred, score) in enumerate(zip(predictions, raw_scores)):
        if pred == -1:
            features = X[i]
            severity = score_to_severity(score)
            desc = _build_description(service, features, score)
            anomalies.append({
                "anomaly_type": "IsolationForest.anomaly",
                "severity": severity,
                "service": service,
                "score": round(float(abs(score)), 4),
                "description": desc,
                "metadata": {
                    "bucket_ts": bucket_keys[i],
                    "total_events": int(features[0]),
                    "error_rate": round(float(features[1]), 4),
                    "warn_rate": round(float(features[2]), 4),
                    "avg_latency_ms": round(float(features[3]), 2),
                    "raw_score": round(float(score), 4),
                },
            })

    return anomalies

# ─────────────────────────────────────────────────────────
# RDS Persistence & SNS Alert Routing
# ─────────────────────────────────────────────────────────
def save_anomalies(conn, anomalies: list[dict]) -> None:
    if not anomalies or not conn:
        return
    import psycopg2.extras
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """
            INSERT INTO anomalies
              (anomaly_type, severity, service, score, description, metadata)
            VALUES %s
            """,
            [
                (
                    a["anomaly_type"],
                    a["severity"],
                    a["service"],
                    a["score"],
                    a["description"],
                    json.dumps(a["metadata"]),
                )
                for a in anomalies
            ],
        )
    conn.commit()
    logger.info("Saved %d anomalies to RDS", len(anomalies))

def send_critical_alerts(anomalies: list[dict]) -> None:
    critical = [a for a in anomalies if a["severity"] in ("CRITICAL", "HIGH")]
    if not critical or not SNS_TOPIC_ARN:
        return

    import boto3
    sns_client = boto3.client("sns")
    lines = [f"🚨 [{a['severity']}] {a['service']}: {a['description']}" for a in critical]
    message_body = (
        f"Cloud Log Analytics Alert\n"
        f"Environment: {ENVIRONMENT}\n"
        f"Timestamp: {datetime.now(timezone.utc).isoformat()}\n\n"
        + "\n".join(lines)
    )

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[{ENVIRONMENT.upper()}] Cloud Log Anomaly Alert ({len(critical)} detected)",
        Message=message_body,
    )
    logger.info("Published %d critical alerts to SNS", len(critical))

# ─────────────────────────────────────────────────────────
# Execution Entry Points
# ─────────────────────────────────────────────────────────
def run_local_detection(raw_events: list[dict]) -> list[dict]:
    """Local evaluation harness for unit tests and local CLI evaluation."""
    buckets = build_time_buckets(raw_events)
    all_anomalies = []
    for service, s_buckets in buckets.items():
        X, keys = extract_feature_matrix(s_buckets)
        anomalies = detect_anomalies(service, X, keys)
        all_anomalies.extend(anomalies)
    return all_anomalies

def lambda_handler(event, context):
    """AWS Lambda entry point triggered by EventBridge every 5 minutes."""
    import boto3
    cw_client = boto3.client("logs")

    end_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    start_ms = end_ms - (WINDOW_MINUTES * 60 * 1000)

    events: list[dict] = []
    kwargs = {
        "logGroupName": LOG_GROUP_NAME,
        "startTime": start_ms,
        "endTime": end_ms,
        "limit": 10_000,
    }

    try:
        while True:
            resp = cw_client.filter_log_events(**kwargs)
            events.extend(resp.get("events", []))
            next_token = resp.get("nextToken")
            if not next_token:
                break
            kwargs["nextToken"] = next_token
    except Exception as exc:
        logger.error("CloudWatch log fetch error: %s", exc)
        return {"status": "error", "message": str(exc)}

    all_anomalies = run_local_detection(events)

    if DB_SECRET_ARN:
        try:
            conn = get_db_conn()
            save_anomalies(conn, all_anomalies)
            conn.close()
        except Exception as exc:
            logger.error("Failed persisting anomalies to RDS: %s", exc)

    if SNS_TOPIC_ARN:
        try:
            send_critical_alerts(all_anomalies)
        except Exception as exc:
            logger.error("Failed sending SNS alert: %s", exc)

    return {
        "status": "success",
        "processed_events": len(events),
        "anomalies_detected": len(all_anomalies),
    }

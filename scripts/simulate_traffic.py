#!/usr/bin/env python3
"""
Cloud Log Analytics — Synthetic Traffic & Anomaly Generator
===========================================================
Generates realistic multi-service application log streams and
injects controlled anomaly bursts (e.g., cache failure 40 errors @ 1800ms).

Usage:
    python scripts/simulate_traffic.py [--url http://localhost:8080] [--rate 5] [--anomaly]
"""

import argparse
import random
import sys
import time
import uuid
from datetime import datetime, timezone

import httpx

SERVICES = ["auth-service", "api-gateway", "payment-api", "cache", "database", "worker"]
LEVELS = ["INFO", "INFO", "INFO", "INFO", "WARN", "ERROR"]

def generate_log_event(service: str, level: str, latency: int, message: str) -> dict:
    return {
        "event_time": datetime.now(timezone.utc).isoformat(),
        "service": service,
        "level": level,
        "message": message,
        "metadata": {
            "environment": "production",
            "region": "us-east-1",
            "trace_id": uuid.uuid4().hex[:12]
        },
        "latency_ms": latency,
        "request_id": f"req_{uuid.uuid4().hex[:8]}",
        "host": f"ip-10-0-1-{random.randint(10, 80)}.ec2.internal"
    }

def send_normal_traffic(base_url: str, count: int = 10):
    events = []
    for _ in range(count):
        srv = random.choice(SERVICES)
        lvl = random.choice(LEVELS) if srv != "cache" else "INFO"
        lat = random.randint(15, 120) if lvl != "ERROR" else random.randint(350, 900)
        msg = f"Handled {srv} transaction with status {200 if lvl == 'INFO' else 500}"
        events.append(generate_log_event(srv, lvl, lat, msg))

    resp = httpx.post(f"{base_url}/logs/batch", json={"events": events}, timeout=5.0)
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Ingested {count} normal logs -> HTTP {resp.status_code}")

def send_cache_anomaly_burst(base_url: str, count: int = 40):
    print(f"\n🚨 [ANOMALY SIMULATION] Injecting {count} ERROR events for 'cache' service with 1800ms latency...")
    resp = httpx.post(f"{base_url}/simulate/anomaly", timeout=5.0)
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Anomaly burst result: {resp.json()}\n")

def main():
    parser = argparse.ArgumentParser(description="Cloud Log Analytics Traffic Simulator")
    parser.add_argument("--url", default="http://localhost:8080", help="Collector base URL")
    parser.add_argument("--rate", type=float, default=2.0, help="Interval between batches (seconds)")
    parser.add_argument("--loop", action="store_true", help="Run indefinitely")
    parser.add_argument("--anomaly", action="store_true", help="Inject anomaly burst immediately")
    args = parser.parse_args()

    print(f"Connecting to Cloud Log Collector at {args.url}...")
    try:
        r = httpx.get(f"{args.url}/health", timeout=3.0)
        print(f"Healthcheck verified: {r.json()}")
    except Exception as e:
        print(f"Warning: could not reach {args.url}/health ({e}). Proceeding anyway...")

    if args.anomaly:
        send_cache_anomaly_burst(args.url)
        return

    iteration = 0
    while True:
        iteration += 1
        # Every 8th iteration, inject cache anomaly burst to demonstrate Isolation Forest detection
        if iteration % 8 == 0:
            send_cache_anomaly_burst(args.url)
        else:
            send_normal_traffic(args.url, count=random.randint(6, 14))

        if not args.loop:
            break
        time.sleep(args.rate)

if __name__ == "__main__":
    main()

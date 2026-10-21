"""
Unit Tests for Cloud Log Analytics FastAPI Endpoints
====================================================
Tests health probes, single ingestion, batch ingestion, query filtering,
metrics summary computation, and simulated anomaly injections.
"""

import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parent.parent / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

try:
    from fastapi.testclient import TestClient
    from src.main import app
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False


class TestCollectorEndpoints(unittest.TestCase):

    def setUp(self):
        if not HAS_FASTAPI:
            self.skipTest("FastAPI not installed in current interpreter")
        self.client = TestClient(app)

    def test_health_endpoint(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["status"], "healthy")
        self.assertIn("timestamp", data)
        self.assertIn("storage", data)

    def test_single_log_ingestion(self):
        payload = {
            "event_time": datetime.now(timezone.utc).isoformat(),
            "service": "AUTH-SERVICE",
            "level": "INFO",
            "message": "User login authenticated successfully",
            "metadata": {"user_id": "usr_99182", "ip": "192.168.1.1"},
            "latency_ms": 42,
            "request_id": "req_test_001",
            "host": "ip-10-0-1-12.ec2.internal"
        }
        response = self.client.post("/logs", json=payload)
        self.assertEqual(response.status_code, 201)
        data = response.json()
        self.assertIn("id", data)

    def test_batch_log_ingestion(self):
        events = [
            {
                "event_time": datetime.now(timezone.utc).isoformat(),
                "service": "payment-api",
                "level": "INFO",
                "message": f"Processed transaction #{i}",
                "latency_ms": 85 + i,
                "request_id": f"req_batch_{i}"
            }
            for i in range(5)
        ]
        response = self.client.post("/logs/batch", json={"events": events})
        self.assertEqual(response.status_code, 201)
        data = response.json()
        self.assertEqual(data["inserted"], 5)

    def test_query_logs_with_filtering(self):
        response = self.client.get("/logs?level=INFO&limit=10")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("total", data)
        self.assertIn("items", data)
        self.assertIsInstance(data["items"], list)

    def test_metrics_summary(self):
        response = self.client.get("/metrics/summary")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("total_events", data)
        self.assertIn("error_rate_pct", data)
        self.assertIn("avg_latency_ms", data)
        self.assertIn("p95_latency_ms", data)
        self.assertIn("anomaly_count", data)

    def test_simulate_anomaly_burst(self):
        response = self.client.post("/simulate/anomaly")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["status"], "anomaly_burst_injected")
        self.assertEqual(data["service"], "cache")
        self.assertEqual(data["events_count"], 40)
        self.assertEqual(data["latency_ms"], 1800)
        self.assertEqual(data["severity"], "CRITICAL")

    def test_get_anomalies_endpoint(self):
        response = self.client.get("/anomalies?limit=5")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIn("items", data)


if __name__ == "__main__":
    unittest.main()

"""
Unit Tests for Isolation Forest Anomaly Detection Engine (AWS Lambda)
=====================================================================
Tests 30-second time-bucket aggregation, 4-dimensional feature extraction,
IsolationForest scoring, and severity threshold classification.
"""

import sys
import unittest
from pathlib import Path
import numpy as np

# Add lambda directory to sys.path so 'handler' can be imported without keyword collision
LAMBDA_DIR = Path(__file__).resolve().parent.parent / "lambda"
if str(LAMBDA_DIR) not in sys.path:
    sys.path.insert(0, str(LAMBDA_DIR))

import handler as detector


class TestAnomalyDetector(unittest.TestCase):

    def test_score_to_severity_mapping(self):
        self.assertEqual(detector.score_to_severity(-0.85), "CRITICAL")
        self.assertEqual(detector.score_to_severity(-0.71), "CRITICAL")
        self.assertEqual(detector.score_to_severity(-0.62), "HIGH")
        self.assertEqual(detector.score_to_severity(-0.51), "HIGH")
        self.assertEqual(detector.score_to_severity(-0.35), "MEDIUM")
        self.assertEqual(detector.score_to_severity(-0.15), "LOW")
        self.assertEqual(detector.score_to_severity(0.05), "LOW")

    def test_build_time_buckets_aggregation(self):
        # Align base timestamp to exact 30-second boundary
        base_sec = (1700000000 // 30) * 30
        base_ts = base_sec * 1000  # ms
        events = [
            {"timestamp": base_ts + 1000, "service": "cache", "level": "INFO", "latency_ms": 25},
            {"timestamp": base_ts + 5000, "service": "cache", "level": "ERROR", "latency_ms": 1800},
            {"timestamp": base_ts + 12000, "service": "cache", "level": "WARN", "latency_ms": 350},
            {"timestamp": base_ts + 35000, "service": "cache", "level": "INFO", "latency_ms": 30},
        ]

        buckets = detector.build_time_buckets(events, bucket_seconds=30)
        self.assertIn("cache", buckets)
        self.assertEqual(len(buckets["cache"]), 2)

        first_bucket_key = sorted(buckets["cache"].keys())[0]
        b1 = buckets["cache"][first_bucket_key]
        self.assertEqual(b1["total"], 3)
        self.assertEqual(b1["errors"], 1)
        self.assertEqual(b1["warns"], 1)
        self.assertEqual(b1["total_latency"], 2175)

    def test_extract_feature_matrix(self):
        service_buckets = {
            1000: {"total": 50, "errors": 0, "warns": 2, "total_latency": 2500, "count_latency": 50},
            1030: {"total": 40, "errors": 40, "warns": 0, "total_latency": 72000, "count_latency": 40},
        }

        X, keys = detector.extract_feature_matrix(service_buckets)
        self.assertIsInstance(X, np.ndarray)
        self.assertEqual(X.shape, (2, 4))
        self.assertEqual(keys, [1000, 1030])

        # Row 0: Normal
        self.assertEqual(X[0][0], 50.0)      # total
        self.assertEqual(X[0][1], 0.0)       # error rate
        self.assertEqual(X[0][2], 0.04)      # warn rate
        self.assertEqual(X[0][3], 50.0)      # avg latency

        # Row 1: Anomalous spike
        self.assertEqual(X[1][0], 40.0)      # total
        self.assertEqual(X[1][1], 1.0)       # 100% error rate
        self.assertEqual(X[1][2], 0.0)       # warn rate
        self.assertEqual(X[1][3], 1800.0)    # 1800ms avg latency


if __name__ == "__main__":
    unittest.main()

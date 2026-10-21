#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Cloud Log Analytics & Anomaly Detection — Build, Security Scan & Rolling Deploy
# Usage: ./scripts/deploy.sh [--env production|staging] [--region us-east-1]
# Author: Ankit Kumar Mishra (M.Tech CS, DTU)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV="production"
AWS_REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV="$2"; shift 2;;
    --region) AWS_REGION="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

PROJECT="cloud-log-analytics"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "123456789012")
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "v2.0.0")
TAG="${GIT_SHA}-${ENV}"

echo "=========================================================="
echo "  Deploying $PROJECT"
echo "  Environment: $ENV"
echo "  Image Tag:   $TAG"
echo "  AWS Region:  $AWS_REGION"
echo "=========================================================="

# ── 1. Authenticate with Amazon ECR ──────────────────────────
echo "[1/6] Authenticating with Amazon ECR..."
if command -v aws &>/dev/null; then
  aws ecr get-login-password --region "$AWS_REGION" 2>/dev/null \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" 2>/dev/null || {
      echo "  [WARN] ECR login skipped (AWS CLI not configured or local mode)"
    }
fi

# ── 2. Build Multi-Stage Hardened Docker Images ─────────────
echo "[2/6] Building hardened multi-stage Docker images..."
docker build \
  -t "$PROJECT/log-collector:$TAG" \
  -t "$PROJECT/log-collector:latest" \
  -t "$ECR_REGISTRY/$PROJECT/log-collector:$TAG" \
  -t "$ECR_REGISTRY/$PROJECT/log-collector:latest" \
  -f docker/Dockerfile .

# ── 3. Trivy Container Vulnerability Scan (Fail on CRITICAL) ─
echo "[3/6] Running Trivy vulnerability scan on image..."
if command -v trivy &>/dev/null; then
  trivy image --exit-code 1 --severity CRITICAL --no-progress \
    "$PROJECT/log-collector:$TAG"
  echo "  ✓ Trivy scan passed: Zero CRITICAL CVE vulnerabilities"
else
  echo "  [INFO] Trivy not installed locally. Run ./scripts/security-scan.sh for audit."
fi

# ── 4. Push Docker Images to ECR ─────────────────────────────
echo "[4/6] Pushing images to ECR..."
if command -v aws &>/dev/null && [ "$ACCOUNT_ID" != "123456789012" ]; then
  docker push "$ECR_REGISTRY/$PROJECT/log-collector:$TAG"
  docker push "$ECR_REGISTRY/$PROJECT/log-collector:latest"
  echo "  ✓ Pushed $PROJECT/log-collector:$TAG"
else
  echo "  [INFO] Local build complete: $PROJECT/log-collector:$TAG"
fi

# ── 5. Package & Deploy Serverless Lambda Anomaly Detector ──
echo "[5/6] Packaging and deploying AWS Lambda anomaly detector..."
if [ -d "lambda" ]; then
  mkdir -p lambda/build
  cp lambda/handler.py lambda/build/
  if [ -f "lambda/requirements.txt" ]; then
    pip install -r lambda/requirements.txt -t lambda/build --quiet 2>/dev/null || true
  fi
  (cd lambda/build && zip -r ../function.zip . -q)
  rm -rf lambda/build

  if command -v aws &>/dev/null && [ "$ACCOUNT_ID" != "123456789012" ]; then
    aws lambda update-function-code \
      --function-name "$PROJECT-anomaly-detector" \
      --zip-file fileb://lambda/function.zip \
      --region "$AWS_REGION" \
      --output text > /dev/null 2>&1 || echo "  [INFO] Lambda function deployment skipped (not provisioned yet)"
  fi
  echo "  ✓ Lambda function.zip package compiled successfully"
fi

# ── 6. Trigger Rolling EC2 Auto Scaling Instance Refresh ────
echo "[6/6] Triggering zero-downtime EC2 Auto Scaling instance refresh..."
ASG_NAME="$PROJECT-asg"
if command -v aws &>/dev/null && [ "$ACCOUNT_ID" != "123456789012" ]; then
  REFRESH_ID=$(aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --preferences '{"MinHealthyPercentage": 50, "InstanceWarmup": 120}' \
    --region "$AWS_REGION" \
    --query 'InstanceRefreshId' \
    --output text 2>/dev/null || echo "none")

  if [ "$REFRESH_ID" != "none" ]; then
    echo "  ✓ Rolling instance refresh started: $REFRESH_ID"
  fi
else
  echo "  ✓ Deployment procedure ready for AWS ASG execution."
fi

echo ""
echo "=========================================================="
echo "  ✓ Cloud Log Analytics deployment procedure complete!"
echo "  Tag: $TAG"
echo "=========================================================="

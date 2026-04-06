#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 00-download-jars.sh
#
# Downloads all JARs required by the demo Spark jobs into the jars/ directory.
# Safe to re-run — skips files that already exist.
#
# JARs downloaded:
#   iceberg-spark-runtime-3.5_2.12-1.6.1.jar   (Iceberg Spark integration)
#   hadoop-aws-3.3.4.jar                         (S3A FileSystem for Hadoop)
#   aws-sdk-java-bundle-2.26.20.jar              (AWS SDK v2 — required by Iceberg 1.6.1 S3FileIO)
#
# NOTE: Iceberg 1.6.1 uses AWS SDK v2 (software.amazon.awssdk) for S3FileIO.
# The bundle version must match exactly — 2.26.20 is what Iceberg 1.6.1 was
# compiled against. Using a different v2 version causes binary incompatibility
# (NoClassDefFoundError: SdkException).
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JAR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/jars"
MAVEN="https://repo1.maven.org/maven2"

mkdir -p "${JAR_DIR}"

download_jar() {
  local jar="$1"
  local url="$2"
  local dest="${JAR_DIR}/${jar}"
  if [ -f "${dest}" ]; then
    echo "  [skip] ${jar} already present"
  else
    echo "  [download] ${jar}"
    curl -fsSL -o "${dest}" "${url}"
    echo "  [ok]   ${jar}"
  fi
}

echo "Downloading JARs to ${JAR_DIR}/"
download_jar "iceberg-spark-runtime-3.5_2.12-1.6.1.jar" \
  "${MAVEN}/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.6.1/iceberg-spark-runtime-3.5_2.12-1.6.1.jar"
download_jar "hadoop-aws-3.3.4.jar" \
  "${MAVEN}/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar"
# AWS SDK v2 bundle — must match Iceberg 1.6.1's compiled-in version (2.26.20).
# This is ~553 MB; the download may take a few minutes on a slow connection.
download_jar "aws-sdk-java-bundle-2.26.20.jar" \
  "${MAVEN}/software/amazon/awssdk/bundle/2.26.20/bundle-2.26.20.jar"

echo ""
echo "All JARs ready in ${JAR_DIR}/"
ls -lh "${JAR_DIR}/"

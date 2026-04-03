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
#   aws-java-sdk-bundle-1.12.262.jar             (AWS SDK v1 for S3A)
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
download_jar "aws-java-sdk-bundle-1.12.262.jar" \
  "${MAVEN}/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar"

echo ""
echo "All JARs ready in ${JAR_DIR}/"
ls -lh "${JAR_DIR}/"

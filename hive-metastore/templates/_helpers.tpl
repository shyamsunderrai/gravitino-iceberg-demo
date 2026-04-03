{{/*
  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
*/}}

{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "hive-metastore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hive-metastore.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart name and version label.
*/}}
{{- define "hive-metastore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "hive-metastore.labels" -}}
app: {{ include "hive-metastore.name" . }}
chart: {{ include "hive-metastore.chart" . }}
release: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "hive-metastore.selectorLabels" -}}
app: {{ include "hive-metastore.name" . }}
release: {{ .Release.Name }}
{{- end -}}

{{/*
MySQL service hostname within the cluster.
*/}}
{{- define "hive-metastore.mysqlHost" -}}
{{- printf "%s-mysql" (include "hive-metastore.fullname" .) -}}
{{- end -}}

{{/*
Full image reference for the Hive Metastore container.
*/}}
{{- define "hive-metastore.image" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{/*
Full image reference for the MySQL container.
*/}}
{{- define "hive-metastore.mysqlImage" -}}
{{- printf "%s/%s:%s" .Values.mysql.image.registry .Values.mysql.image.repository .Values.mysql.image.tag -}}
{{- end -}}

{{/*
Name of the Secret that holds all sensitive credentials.
*/}}
{{- define "hive-metastore.secretName" -}}
{{- printf "%s-secrets" (include "hive-metastore.fullname" .) -}}
{{- end -}}

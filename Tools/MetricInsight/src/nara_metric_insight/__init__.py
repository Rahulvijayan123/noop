"""Nara metric insight worker.

Drains public.metric_insight_jobs (20261008000000_metric_insights.sql): for each job it loads the owner's
data through owner-scoped tools, lets Prime Agent reason over the computed evidence, validates the answer and
publishes it with metric_insight_publish_v1. See README.md.
"""

ANALYSIS_VERSION = "metric-insight-1"

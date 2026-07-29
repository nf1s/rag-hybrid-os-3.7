#!/bin/sh
set -e
ES_URL="${ES_URL:-http://hybrid-search-single:9200}"
echo "Waiting for OpenSearch at $ES_URL..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL" | grep -q 200; do
  sleep 2
done
echo "OpenSearch is ready. Waiting for article index template..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_index_template/article" | grep -q 200; do
  sleep 2
done
echo "Template exists. Waiting for chunking pipeline..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_ingest/pipeline/article-chunking" | grep -q 200; do
  sleep 2
done
echo "Pipeline exists. Checking for existing articles..."
COUNT=$(curl -s "$ES_URL/article/_count" | jq -r '.count // 0')
if [ "$COUNT" -gt 0 ]; then
  echo "Article index already has $COUNT documents — skipping seed."
  exit 0
fi
echo "Seeding data..."
jq -c '.[] | {index: {_id: .id}}, {id, title, body}' /seed/seed.json | \
  curl -s -XPOST "$ES_URL/article/_bulk?pipeline=article-chunking" -H 'Content-Type: application/x-ndjson' --data-binary @-
echo "Seed complete."

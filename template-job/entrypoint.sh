#!/bin/sh
set -e
ES_URL="${ES_URL:-http://hybrid-search-single:9200}"
echo "Waiting for OpenSearch at $ES_URL..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL" | grep -q 200; do
  sleep 2
done
echo "Applying article index template..."
curl -s -XPUT "$ES_URL/_index_template/article" \
  -H 'Content-Type: application/json' \
  -d @/template/mappings.json
echo "Template applied."

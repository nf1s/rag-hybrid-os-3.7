#!/bin/sh
set -e
ES_URL="${ES_URL:-http://hybrid-search-single:9200}"

echo "Waiting for OpenSearch at $ES_URL..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL" | grep -q 200; do
  sleep 2
done

echo "Waiting for index template..."
until curl -s -o /dev/null -w '%{http_code}' "$ES_URL/_index_template/article" | grep -q 200; do
  sleep 2
done

echo "Configuring ML Commons settings..."
curl -s -XPUT "$ES_URL/_cluster/settings" \
  -H 'Content-Type: application/json' \
  -d '{
    "persistent": {
      "plugins.ml_commons.allow_registering_model_via_url": true,
      "plugins.ml_commons.only_run_on_ml_node": false,
      "plugins.ml_commons.native_memory_threshold": 99
    }
  }' | jq .

MODEL_NAME="huggingface/sentence-transformers/all-MiniLM-L12-v2"

MODEL_REGISTERED_NOW=false

model_state() {
  curl -s "$ES_URL/_plugins/_ml/models/$1" | jq -r '.model_state // "NOT_FOUND"'
}

ensure_model_deployed() {
  while true; do
    SEARCH=$(curl -s -XPOST "$ES_URL/_plugins/_ml/models/_search" \
      -H 'Content-Type: application/json' \
      -d "{
        \"query\": {
          \"match\": {\"name\": \"$MODEL_NAME\"}
        },
        \"size\": 1,
        \"sort\": [{\"model_version\": \"desc\"}]
      }")
    MODEL_ID=$(echo "$SEARCH" | jq -r '.hits.hits[0]._source.model_id // empty')

    if [ -n "$MODEL_ID" ]; then
      STATE=$(model_state "$MODEL_ID")
      echo "Found existing model: $MODEL_ID (state=$STATE)"
      case "$STATE" in
        "DEPLOYED")
          echo "Model already deployed."
          return 0 ;;
        "UNDEPLOYED" | "DEPLOY_FAILED")
          echo "Redeploying model..."
          DEPLOY_RESP=$(curl -s -XPOST "$ES_URL/_plugins/_ml/models/$MODEL_ID/_deploy")
          TASK_ID=$(echo "$DEPLOY_RESP" | jq -r '.task_id // empty')
          echo "$DEPLOY_RESP" | jq .
          if [ -n "$TASK_ID" ]; then
            echo "Deploy task: $TASK_ID. Waiting for task to complete..."
            while true; do
              TASK_RESP=$(curl -s "$ES_URL/_plugins/_ml/tasks/$TASK_ID")
              STATE=$(echo "$TASK_RESP" | jq -r '.state // "UNKNOWN"')
              echo "  Task state: $STATE"
              case "$STATE" in
                "COMPLETED") break ;;
                "FAILED")
                  echo "  Deploy failed: $(echo "$TASK_RESP" | jq '.error // "unknown"')"
                  sleep 5
                  continue 2 ;;
                *) sleep 10 ;;
              esac
            done
          fi
          # Second: wait for model to report deployed
          for i in $(seq 1 12); do
            STATE=$(model_state "$MODEL_ID")
            case "$STATE" in
              "DEPLOYED")
                echo "Model deployed."
                return 0 ;;
              "DEPLOY_FAILED")
                echo "  Deploy failed. Retrying..."
                sleep 5
                continue 2 ;;
              *) sleep 5 ;;
            esac
          done
          echo "  Deployment timed out. Retrying..."
          sleep 5
          continue ;;
        "DEPLOYING" | "CREATED")
          echo "Model is $STATE. Waiting..."
          for i in $(seq 1 60); do
            STATE=$(model_state "$MODEL_ID")
            case "$STATE" in
              "DEPLOYED")
                echo "Model deployed."
                return 0 ;;
              "DEPLOY_FAILED")
                echo "  Deploy failed. Retrying..."
                sleep 5
                continue 2 ;;
              *) sleep 10 ;;
            esac
          done
          echo "  Wait timed out. Retrying..."
          sleep 5
          continue ;;
      esac
    fi

    MODEL_REGISTERED_NOW=true

    echo "Registering and deploying model..."
    REG=$(curl -s -XPOST "$ES_URL/_plugins/_ml/models/_register?deploy=true" \
      -H 'Content-Type: application/json' \
      -d "{
        \"name\": \"$MODEL_NAME\",
        \"version\": \"1.0.2\",
        \"model_format\": \"TORCH_SCRIPT\"
      }")
    echo "Registration: $REG"
    TASK_ID=$(echo "$REG" | jq -r '.task_id // empty')
    if [ -z "$TASK_ID" ]; then
      echo "No task_id in response, retrying..."
      sleep 5
      continue
    fi

    echo "Task ID: $TASK_ID. Waiting for task to complete..."
    while true; do
      TASK_RESP=$(curl -s "$ES_URL/_plugins/_ml/tasks/$TASK_ID")
      STATE=$(echo "$TASK_RESP" | jq -r '.state // "UNKNOWN"')
      echo "  Task state: $STATE"
      case "$STATE" in
        "COMPLETED")
          MODEL_ID=$(echo "$TASK_RESP" | jq -r '.model_id // empty')
          break ;;
        "FAILED")
          echo "  Task error: $(echo "$TASK_RESP" | jq '.error // "unknown"')"
          echo "  Retrying registration..."
          sleep 5
          continue 2 ;;
        *) sleep 10 ;;
      esac
    done

    echo "Task complete. Model ID: $MODEL_ID"
    echo "Waiting for model deployment..."
    for i in $(seq 1 60); do
      STATE=$(model_state "$MODEL_ID")
      case "$STATE" in
        "DEPLOYED")
          echo "Model deployed."
          return 0 ;;
        "DEPLOY_FAILED" | "NOT_FOUND")
          echo "  Model $STATE. Re-registering..."
          sleep 3
          continue 2 ;;
        *)
          if [ "$i" -eq 60 ]; then
            echo "  Deployment timed out. Re-registering..."
            continue 2
          fi
          sleep 10 ;;
      esac
    done
  done
}

ensure_model_deployed

echo "Updating index template with semantic field..."
TEMPLATE=$(cat <<TMPL
{
  "index_patterns": ["article"],
  "template": {
    "settings": {
      "index.knn": true,
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "id": { "type": "keyword" },
        "title": { "type": "text", "analyzer": "standard" },
        "body": {
          "type": "semantic",
          "model_id": "$MODEL_ID"
        }
      }
    }
  },
  "priority": 100
}
TMPL
)
curl -s -XPUT "$ES_URL/_index_template/article" \
  -H 'Content-Type: application/json' \
  -d "$TEMPLATE" | jq .
echo "Index template updated."

echo "Creating chunking pipeline..."
curl -s -XPUT "$ES_URL/_ingest/pipeline/article-chunking" \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Chunk article body into 100-token passages with 15% overlap",
    "processors": [
      {
        "text_chunking": {
          "algorithm": {
            "fixed_token_length": {
              "token_limit": 100,
              "overlap_rate": 0.15,
              "tokenizer": "standard"
            }
          },
          "field_map": {
            "body": "body_chunks"
          }
        }
      }
    ]
  }' | jq .
echo "Pipeline created."

echo "Creating hybrid search pipeline with z_score normalization..."
curl -s -XPUT "$ES_URL/_search/pipeline/hybrid-search-pipeline" \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Z-score normalize and combine neural + full-text scores",
    "phase_results_processors": [
      {
        "normalization-processor": {
          "normalization": {
            "technique": "z_score"
          },
          "combination": {
            "technique": "arithmetic_mean",
            "parameters": {
              "weights": [0.59, 0.41]
            }
          }
        }
      }
    ]
  }' | jq .
echo "Search pipeline created."

if [ "$MODEL_REGISTERED_NOW" = "true" ]; then
  echo "Deleting existing article index so it is recreated with new template..."
  curl -s -XDELETE "$ES_URL/article" -o /dev/null -w "delete status: %{http_code}\n" || true
else
  echo "Model was already deployed — keeping article index intact."
fi

echo "Model job complete."

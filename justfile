deploy:
    skaffold run

delete:
    skaffold delete

render:
    skaffold render

logs:
    kubectl logs -n opensearch -l app.kubernetes.io/instance=opensearch -f

logs-dashboards:
    kubectl logs -n opensearch -l app.kubernetes.io/instance=dashboards -f

port-forward:
    kubectl port-forward -n opensearch svc/hybrid-search-single 9200:9200

port-forward-dashboards:
    kubectl port-forward -n opensearch svc/opensearch-opensearch-dashboards 5601:5601

port-forward-ui:
    kubectl port-forward -n opensearch svc/ui 8080:80

port-forward-rag:
    kubectl port-forward -n opensearch svc/rag-api 8000:8000

seed:
    skaffold run

reseed:
    kubectl delete job seed-job -n opensearch --ignore-not-found
    skaffold run

seed-logs:
    kubectl logs -n opensearch job/seed-job

template-logs:
    kubectl logs -n opensearch job/template-job

model-logs:
    kubectl logs -n opensearch job/model-job

rag-logs:
    kubectl logs -n opensearch deployment/rag-api -f

rag-restart:
    kubectl rollout restart -n opensearch deployment/rag-api

all-logs:
    kubectl logs -n opensearch deployment/rag-api -f &
    kubectl logs -n opensearch deployment/ui -f

ps:
    kubectl get pods -n opensearch

svc:
    kubectl get svc -n opensearch

curl:
    curl -s http://localhost:9200 | python3 -m json.tool

curl-rag:
    curl -s http://localhost:8000/api/rag/health | python3 -m json.tool

rebuild:
    rm -rf charts/hybrid-search/charts charts/hybrid-search/Chart.lock
    helm dependency update charts/hybrid-search/

ollama-url:
    @echo "Set OLLAMA_URL in charts/rag-api/values.yaml to your host's Ollama endpoint."
    @echo "  macOS Docker Desktop: http://host.docker.internal:11434"
    @echo "  Linux (hostNetwork):  http://localhost:11434"
    @echo "  Minikube:            $(minikube ip):11434"

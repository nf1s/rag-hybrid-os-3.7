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

ps:
    kubectl get pods -n opensearch

svc:
    kubectl get svc -n opensearch

curl:
    curl -s http://localhost:9200 | python3 -m json.tool

rebuild:
    rm -rf charts/hybrid-search/charts charts/hybrid-search/Chart.lock
    helm dependency update charts/hybrid-search/

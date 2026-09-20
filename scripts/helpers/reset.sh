set -u

BASEDIR=$(dirname "$(realpath "$0")")

source ${BASEDIR}/.env.pg_creds

kubectl delete ns app-restored --grace-period=0 --force --ignore-not-found

kubectl delete pv demoapp-orig-pv demoapp-restored-pv --ignore-not-found

docker exec -it backup-demo-worker rm -rf /mnt/data-app /mnt/data-restored

docker exec -it backup-demo-worker mkdir -p /mnt/data-app /mnt/data-restored

docker exec -it backup-demo-worker chmod -R 777 /mnt/data-app /mnt/data-restored

kubectl apply -f ${BASEDIR}/../../k8s/storage.yaml

kubectl create namespace app

kubectl apply -f ${BASEDIR}/../../k8s/postgres-init-config.yaml -n app

kubectl create secret generic demoapp-db-secrets \
  --namespace=app \
  --from-literal=username=${POSTGRES_USER} \
  --from-literal=password=${POSTGRES_PASSWORD} \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f ${BASEDIR}/../../k8s/demoapp.yaml


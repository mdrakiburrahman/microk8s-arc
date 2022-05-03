CERTS_DIR='/workspaces/microk8s-arc/kubernetes/otel/certs'
CONTAINER_CERTS_DIR='/var/run/secrets/managed/certificates'
NAMESPACE='arc'
OTEL_CONFIGMAP='otel-cluster-config'

rm -rf $CERTS_DIR
mkdir -p $CERTS_DIR

# CA
kubectl get configmap -n $NAMESPACE cluster-configmap -o=jsonpath='{.data.cluster-ca-certificate\.crt}' > $CERTS_DIR/ca.crt

# Fluentbit
kubectl cp -n $NAMESPACE -c fluentbit logsdb-0:$CONTAINER_CERTS_DIR/fluentbit/fluentbit-certificate.pem $CERTS_DIR/fluentbit-cert.pem
kubectl cp -n $NAMESPACE -c fluentbit logsdb-0:$CONTAINER_CERTS_DIR/fluentbit/fluentbit-privatekey.pem $CERTS_DIR/fluentbit-key.pem

# Create configMap
kubectl create configmap $OTEL_CONFIGMAP -n $NAMESPACE --from-file=$CERTS_DIR/ca.crt --from-file=$CERTS_DIR/fluentbit-cert.pem --from-file=$CERTS_DIR/fluentbit-key.pem
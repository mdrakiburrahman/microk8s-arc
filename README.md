# microk8s for Arc
Environment to deploy Arc Data Services in a fresh Microk8s Cluster.

## Microk8s deployment

Run these in local **PowerShell in _Admin mode_** to spin up via Multipass:

> Run with Docker Desktop turned off so `microk8s-vm` has no trouble booting up

**Multipass notes**
* `Multipassd` is the main binary available here: `C:\Program Files\Multipass\bin`
* Default VM files end up here: `C:\Windows\System32\config\systemprofile\AppData\Roaming\multipassd`
* Generated kubeconfig available here: `C:\Users\mdrrahman\AppData\Local\MicroK8s\config`


```PowerShell
# Delete old one (if any)
multipass list
multipass delete microk8s-vm
multipass purge

# Single node K8s cluster
# Latest releases: https://microk8s.io/docs/release-notes
microk8s install "--cpu=4" "--mem=12" "--disk=25" "--channel=1.22/stable" -y
# Seems to work better for smaller VMs

# Launched: microk8s-vm
# 2022-03-05T23:05:51Z INFO Waiting for automatic snapd restart...
# ...

# Allow priveleged containers
multipass shell microk8s-vm
# This shells us in

sudo bash -c 'echo "--allow-privileged" >> /var/snap/microk8s/current/args/kube-apiserver'

exit # Exit out from Microk8s vm

# Start microk8s
microk8s status --wait-ready

# Get IP address of node for MetalLB range
microk8s kubectl get nodes -o wide
# NAME          STATUS   ROLES    AGE   VERSION                    INTERNAL-IP      EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
# microk8s-vm   Ready    <none>   75s   v1.22.6-3+7ab10db7034594   172.31.121.26    <none>        Ubuntu 18.04.6 LTS   4.15.0-169-generic   containerd://1.5.2

# Enable features needed for arc
microk8s enable dns storage metallb ingress
# Enter CIDR for MetalLB: 

# 172.31.121.50-172.31.121.70


# This must be in the same range as the VM above!

# Access via kubectl in this container
$DIR = "C:\Users\mdrrahman\Documents\GitHub\microk8s-arc\microk8s"
microk8s config view > $DIR\config # Export kubeconfig
```

Turn on Docker Desktop.

Now we go into our VSCode Container:

```bash
rm -rf $HOME/.kube
mkdir $HOME/.kube
cp microk8s/config $HOME/.kube/config
dos2unix $HOME/.kube/config
cat $HOME/.kube/config

# Check kubectl works
kubectl get nodes
# NAME          STATUS   ROLES    AGE   VERSION
# microk8s-vm   Ready    <none>   29m   v1.22.6-3+7ab10db7034594
kubectl get pods --all-namespaces
# NAMESPACE        NAME                                       READY   STATUS    RESTARTS   AGE
# kube-system      coredns-7f9c69c78c-s9mnr                   1/1     Running   0          27m
# kube-system      calico-kube-controllers-7bb79d6cbc-rgtm7   1/1     Running   0          29m
# kube-system      calico-node-kgd6n                          1/1     Running   0          29m
# kube-system      hostpath-provisioner-566686b959-v2dk6      1/1     Running   0          26m
# metallb-system   speaker-vfmsj                              1/1     Running   0          24m
# metallb-system   controller-559b68bfd8-jw4x4                1/1     Running   0          24m
# ingress          nginx-ingress-microk8s-controller-lbs8t    1/1     Running   0          23m
kubectl get storageclass
# NAME                          PROVISIONER            RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
# microk8s-hostpath (default)   microk8s.io/hostpath   Delete          Immediate           false                  27m
```

---

## Create Monitoring certs

We create monitoring certs via `openssl`:
```bash
##################################################
# Optional: Create SSL certs for Monitoring SVCs
##################################################
# Create monitoring certs
cd /workspaces/microk8s-arc/kubernetes/monitoring
./create-monitoring-tls-files.sh arc certs
# We see:
# .
# ├── certs
# │   ├── logsui-cert.pem
# │   ├── logsui-key.pem
# │   ├── logsui-ssl.conf
# │   ├── metricsui-cert.pem
# │   ├── metricsui-key.pem
# │   └── metricsui-ssl.conf

# Create namespace
kubectl create ns arc

# Read file and base64 encode, store in variable
logs_base64Certificate=$(cat /workspaces/microk8s-arc/kubernetes/monitoring/certs/logsui-cert.pem | base64 -w 0)
logs_base64PrivateKey=$(cat /workspaces/microk8s-arc/kubernetes/monitoring/certs/logsui-key.pem | base64 -w 0)
metrics_base64Certificate=$(cat /workspaces/microk8s-arc/kubernetes/monitoring/certs/metricsui-cert.pem | base64 -w 0)
metrics_base64PrivateKey=$(cat /workspaces/microk8s-arc/kubernetes/monitoring/certs/metricsui-key.pem | base64 -w 0)

# Create logs UI Secret: logsui-certificate-secret
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: logsui-certificate-secret
  namespace: arc
type: Opaque
data:
  certificate.pem: $logs_base64Certificate
  privatekey.pem: $logs_base64PrivateKey
EOF

# Create Metrics UI Secret: metricsui-certificate-secret
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: metricsui-certificate-secret
  namespace: arc
type: Opaque
data:
  certificate.pem: $metrics_base64Certificate
  privatekey.pem: $metrics_base64PrivateKey
EOF
```
---

## Azure creds and login

```bash
cd /workspaces/microk8s-arc/kubernetes

# Deployment variables
export random=$(echo $RANDOM | md5sum | head -c 5; echo;)
export resourceGroup=(raki-arc-test-$random)
export AZDATA_USERNAME='boor'
export AZDATA_PASSWORD='acntorPRESTO!'
export arcDcName='arc-dc'
export azureLocation='eastus'
export AZDATA_LOGSUI_USERNAME=$AZDATA_USERNAME
export AZDATA_METRICSUI_USERNAME=$AZDATA_USERNAME
export AZDATA_LOGSUI_PASSWORD=$AZDATA_PASSWORD
export AZDATA_METRICSUI_PASSWORD=$AZDATA_PASSWORD

# Login as service principal
az login --service-principal --username $spnClientId --password $spnClientSecret --tenant $spnTenantId
az account set --subscription $subscriptionId

# Adding Azure Arc CLI extensions
az config set extension.use_dynamic_install=yes_without_prompt

# Create Azure Resource Group
az group create --name $resourceGroup --location $azureLocation
```

---
## Microk8s custom profile for Data Controller

```bash
# Create custom profile for Microk8s - ok to use AKS since we have LoadBalancer
az arcdata dc config init --source azure-arc-aks-default-storage --path custom --force

# Just need to replace storageClass
sed -i -e 's/default/microk8s-hostpath/g' custom/control.json
```

---

## Option 1: Arc deployment - Indirect Mode

```bash
# If the 2 logs secrets above are deployed to Arc Namespace, DC should start with them and apply to Kibana, Grafana

# Create with the AKS profile
az arcdata dc create --path './custom' \
                     --k8s-namespace arc \
                     --name $arcDcName \
                     --subscription $subscriptionId \
                     --resource-group $resourceGroup \
                     --location $azureLocation \
                     --connectivity-mode indirect \
                     --use-k8s

# Monitor Data Controller
watch -n 20 kubectl get datacontroller -n arc
```

---

## Option 2: Arc deployment - Direct Mode

```bash
# Connect Arc Cluster
export connectedClusterName='Microk8s-K8s'

az connectedk8s connect --name $connectedClusterName \
                        --resource-group $resourceGroup \
                        --location 'eastus' \
                        --kube-config $HOME/.kube/config \
                        --kube-context microk8s

# Observe pods coming up for HAIKU and Arc Data
watch -n 10 kubectl get pods -A

# Create Azure Arc enabled Data Services extension for a specific release
az k8s-extension create --name arc-data-services \
                        --extension-type microsoft.arcdataservices \
                        --cluster-type connectedClusters \
                        --cluster-name $connectedClusterName \
                        --resource-group $resourceGroup \
                        --auto-upgrade false \
                        --scope cluster \
                        --release-namespace arc \
                        --config Microsoft.CustomLocation.ServiceAccount=sa-arc-bootstrapper \
                        --config systemDefaultValues.image=mcr.microsoft.com/arcdata/arc-bootstrapper:v1.4.1_2022-03-08

# Retrieve System Assigned Service Principal for Arc Data Extension
export MSI_OBJECT_ID=`az k8s-extension show --resource-group $resourceGroup  --cluster-name $connectedClusterName  --cluster-type connectedClusters --name arc-data-services | jq '.identity.principalId' | tr -d \"`

# Enable cluster-connect and custom-location connected cluster features
az connectedk8s enable-features -n $connectedClusterName \
                                -g $resourceGroup \
                                --kube-config $HOME/.kube/config \
                                --custom-locations-oid '51dfe1e8-70c6-4de5-a08e-e18aff23d815' \
                                --features cluster-connect custom-locations

# Setup Roles for Data Service Extension Service Principal
az role assignment create --assignee $MSI_OBJECT_ID --role 'Contributor' --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
az role assignment create --assignee $MSI_OBJECT_ID --role 'Monitoring Metrics Publisher' --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"

# Fetch Host Resource ID
export connectedClusterId=`az connectedk8s show -g $resourceGroup -n $connectedClusterName --query id -o tsv`

# Fetch Azure Kubernetes Cluster Extension ID
export extensionId=`az k8s-extension show -g $resourceGroup -c $connectedClusterName --cluster-type connectedClusters --name arc-data-services --query id -o tsv`

# Create a new Azure Custom Location mapped to arc namespace
az customlocation create --name 'arc-cl' \
                         --resource-group $resourceGroup \
                         --namespace arc \
                         --host-resource-id $connectedClusterId \
                         --cluster-extension-ids $extensionId

# Data Controller deployment
cd /workspaces/microk8s-arc/kubernetes

# Create with the AKS profile
az arcdata dc create --path './custom' \
                     --custom-location 'arc-cl' \
                     --name $arcDcName \
                     --subscription $subscriptionId \
                     --resource-group $resourceGroup \
                     --location $azureLocation \
                     --connectivity-mode direct

```
---
## Validate Monitoring endpoint:
```bash
status=$(kubectl get monitors monitorstack -n arc -o json | jq -r ".status")
logsUI_ip=$(jq -r ".logSearchDashboard" <<< $status)
metricsUI_ip=$(jq -r ".metricsDashboard" <<< $status)

echo $"logsUI: ${logsUI_ip}"
echo $"metricsUI: ${metricsUI_ip}"
```

---

Add cert to `Trusted Root Certification Authorities` for Windows to view via browser:

```PowerShell
# Import certs
Import-Certificate -FilePath C:\Users\mdrrahman\Documents\GitHub\microk8s-arc\kubernetes\monitoring\certs\logsui-cert.pem -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath C:\Users\mdrrahman\Documents\GitHub\microk8s-arc\kubernetes\monitoring\certs\metricsui-cert.pem -CertStoreLocation Cert:\LocalMachine\Root

# Add entry to host file
$HostFile = 'C:\Windows\System32\drivers\etc\hosts'
$logsUI = '172.26.218.112' # Replace from above
$metricsUI = '172.26.218.111' # Replace from above

Add-content -path $HostFile -value "$logsUI `t logsui-svc"
Add-content -path $HostFile -value "$metricsUI `t metricsui-svc"

# Browse to UI via browser
# https://metricsui-svc:3000
# https://logsui-svc:5601
```

---

## Create SQL MI
```bash

# Create SQL MI
kubectl apply -f sql-mi/sql-gp-1.yaml

# And we can get the connectivity endpoints
kubectl get sqlmi sql-gp-1 -n arc -o json | jq -r ".status.endpoints"
# {
#   "logSearchDashboard": "https://172.27.229.217:5601/app/kibana#/discover?_a=(query:(language:kuery,query:'custom_resource_name:sql-gp-1'))",
#   "metricsDashboard": "https://172.27.229.216:3000/d/40q72HnGk/sql-managed-instance-metrics?var-hostname=sql-gp-1-0",
#   "mirroring": "172.27.229.218:5022",
#   "primary": "172.27.229.218,31433"
# }

# Delete SQL MI
kubectl delete -f sql-mi/sql-gp-1.yaml
kubectl delete pvc -n arc -l=app.kubernetes.io/instance=sql-gp-1

# Create 4 SQL MIs
kubectl apply -f sql-mi/sql-gp-4-together.yaml
```

---

## Tear down cluster

Run in PowerShell:
```PowerShell
microk8s stop
multipass delete microk8s-vm
multipass purge
```

---

### Delete Arc

```bash
# First, need to delete all the MIs
kubectl delete -f sql-mi/sql-gp-1.yaml
kubectl delete pvc -n arc -l=app.kubernetes.io/instance=sql-gp-1

# Delete controller
az arcdata dc delete --name arc-dc --k8s-namespace arc --use-k8s

# Delete CRDs
kubectl delete crd datacontrollers.arcdata.microsoft.com
kubectl delete crd postgresqls.arcdata.microsoft.com
kubectl delete crd sqlmanagedinstances.sql.arcdata.microsoft.com
kubectl delete crd sqlmanagedinstancerestoretasks.tasks.sql.arcdata.microsoft.com
kubectl delete crd dags.sql.arcdata.microsoft.com
kubectl delete crd exporttasks.tasks.arcdata.microsoft.com
kubectl delete crd monitors.arcdata.microsoft.com
kubectl delete crd activedirectoryconnectors.arcdata.microsoft.com
kubectl delete crd kafkas.arcdata.microsoft.com

export mynamespace="arc"

## Delete Cluster roles and Cluster role bindings
kubectl delete clusterrole arcdataservices-extension
kubectl delete clusterrole $mynamespace:cr-arc-metricsdc-reader
kubectl delete clusterrole $mynamespace:cr-arc-dc-watch
kubectl delete clusterrole cr-arc-webhook-job
kubectl delete clusterrole $mynamespace:cr-upgrade-worker

kubectl delete clusterrolebinding $mynamespace:crb-arc-metricsdc-reader
kubectl delete clusterrolebinding $mynamespace:crb-arc-dc-watch
kubectl delete clusterrolebinding crb-arc-webhook-job
kubectl delete clusterrolebinding $mynamespace:crb-upgrade-worker

## Delete mutatingwebhookconfiguration
kubectl delete mutatingwebhookconfiguration arcdata.microsoft.com-webhook-$mynamespace

## Delete namespace
kubectl delete ns $mynamespace
```

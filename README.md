# microk8s for Arc
Environment to deploy Arc Data Services in a fresh Microk8s Cluster.

## Microk8s deployment
> https://microk8s.io/docs/install-alternatives

Run these in local **PowerShell in _Admin mode_** to spin up via Multipass:

> Run with Docker Desktop turned off so `microk8s-vm` has no trouble booting up

**Multipass notes**
* `Multipassd` is the main binary available here: `C:\Program Files\Multipass\bin`
* Default VM files end up here: `C:\Windows\System32\config\systemprofile\AppData\Roaming\multipassd`
* Generated kubeconfig available here: `C:\Users\mdrrahman\AppData\Local\MicroK8s\config`
* Errors go to Event Logs: https://multipass.run/docs/accessing-logs `Windows Logs > Application`
* VHDx is installed here: `C:\Windows\System32\config\systemprofile\AppData\Roaming\multipassd\vault\instances`

### Multipass BSOD due to Hyper-V Dynamic Memory
* https://github.com/canonical/multipass/issues/604
* https://github.com/kubernetes/minikube/issues/1766

> This keeps the memory constant so Hyper-V doesn't kill our K8s cluster.

Open PowerShell as **admin**:
```PowerShell
# Delete old one (if any)
multipass list
multipass delete microk8s-vm
multipass purge

# Single node K8s cluster
# Latest releases: https://microk8s.io/docs/release-notes
microk8s install "--cpu=8" "--mem=32" "--disk=100" "--channel=1.22/stable" -y

# Seems to work better for smaller VMs (when my PSU was bad :-) )

# Launched: microk8s-vm
# 2022-03-05T23:05:51Z INFO Waiting for automatic snapd restart...
# ...

# Stop the VM
microk8s stop

# Turn off Dynamic Memory - when PSU was bad
Set-VMMemory -VMName 'microk8s-vm' -DynamicMemoryEnabled $false -Priority 100
microk8s start

# Allow priveleged containers
multipass shell microk8s-vm
# This shells us in

sudo bash -c 'echo "--allow-privileged" >> /var/snap/microk8s/current/args/kube-apiserver'

exit # Exit out from Microk8s vm

# Start microk8s
microk8s status --wait-ready

# Get IP address of node for MetalLB range
microk8s kubectl get nodes -o wide -o json | jq -r '.items[].status.addresses[]'
# {
#   "address": "172.17.182.143",
#   "type": "InternalIP"
# }
# {
#   "address": "microk8s-vm",
#   "type": "Hostname"
# }

# Enable features needed for arc
microk8s enable dns storage metallb ingress dashboard # rbac # dashboard <> rbac - both causes issues, one is ok
# Enter CIDR for MetalLB: 

# 172.29.114.110-172.29.114.130

# This must be in the same range as the VM above!
```

### Microk8s static IP
> https://github.com/canonical/microk8s/issues/2120
> https://github.com/canonical/microk8s/issues/2452

```bash
multipass shell microk8s-vm
```

### Spit out kubeconfig
```bash
# Access via kubectl in this container
$DIR = "C:\Users\mdrrahman\Documents\GitHub\microk8s-arc\microk8s"
microk8s config view > $DIR\config # Export kubeconfig

# Access Dashboard via proxy
microk8s dashboard-proxy
```

Turn on Docker Desktop.

Now we go into our VSCode Container:

```bash
rm -rf $HOME/.kube
mkdir $HOME/.kube
cp microk8s/config $HOME/.kube/config
dos2unix $HOME/.kube/config
cat $HOME/.kube/config

# Check kubectl works verbosely
kubectl get nodes --v=9

# If the above errors, you probably have a conflicting Container IP - clean it
docker container prune -f
docker inspect -f '{{.Name}} - {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker ps -aq)

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

## Creating a scoped Service Account for deployment

Alternative to `cluster-admin`:

```bash
# ClusterRole, ClusterRoleBinding, ServiceAccount
kubectl apply -f /workspaces/microk8s-arc/microk8s/tina-onboarder-rbac.yaml
# clusterrole.rbac.authorization.k8s.io/arc-data-deployer-cluster-role created
# clusterrolebinding.rbac.authorization.k8s.io/arc-data-deployer-cluster-rolebinding created
# serviceaccount/arc-data-deployer created
```

Generate the kubeconfig:

```bash
# Service Account is in default but because of ClusterRoleBinding it has Cluster scope
namespace=default
serviceAccount=arc-data-deployer
clusterName=microk8s-cluster
server=https://172.21.197.101:16443 # Replace every new cluster

# Cache variables for Kubeconfig
secretName=$(kubectl --namespace $namespace get serviceAccount $serviceAccount -o jsonpath='{.secrets[0].name}')
ca=$(kubectl --namespace $namespace get secret/$secretName -o jsonpath='{.data.ca\.crt}')
token=$(kubectl --namespace $namespace get secret/$secretName -o jsonpath='{.data.token}' | base64 --decode)

# Remove previous cluster-admin kubeconfig
rm $HOME/.kube/config

kubectl get pods --all-namespaces # This will not work since we blew away the kubeconfig
# The connection to the server localhost:8080 was refused - did you specify the right host or port?

# Create scoped kubeconfig
echo "
apiVersion: v1
kind: Config
clusters:
  - name: ${clusterName}
    cluster:
      certificate-authority-data: ${ca}
      server: ${server}
contexts:
  - name: ${serviceAccount}@${clusterName}
    context:
      cluster: ${clusterName}
      namespace: ${namespace}
      user: ${serviceAccount}
users:
  - name: ${serviceAccount}
    user:
      token: ${token}
current-context: ${serviceAccount}@${clusterName}
" >> $HOME/.kube/config

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
# export FEATURE_FLAG_RESOURCE_SYNC=1 # Resource hydration - needs Direct mode!!

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

# Create with the Microk8s profile
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

# Monitor pods
watch -n 10 kubectl get pods -n arc
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
                        --config systemDefaultValues.image=mcr.microsoft.com/arcdata/arc-bootstrapper:v1.4.1_2022-03-08 # March 2022

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
                     --connectivity-mode direct \
                     --cluster-name $connectedClusterName

# April 2022 went through some new additions/breaking changes on errors

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
kubectl delete crd exporttasks.tasks.arcdata.microsoft.com
kubectl delete crd monitors.arcdata.microsoft.com
kubectl delete crd activedirectoryconnectors.arcdata.microsoft.com
kubectl delete crd kafkas.arcdata.microsoft.com
kubectl delete crd failovergroups.sql.arcdata.microsoft.com

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
---

### Upgrade Arc

Get all running container versions
``` bash
# Get all images
kubectl get pods -n arc -o=jsonpath="{range .items[*]}{'\n'}{.metadata.name}{':\t'}{range .spec.containers[*]}{.image}{', '}{end}{end}"
```

List available upgrades:
```bash
az arcdata dc list-upgrades -k arc
# Found 7 valid versions.  The current datacontroller version is v1.5.0_2022-04-05.
# v1.5.0_2022-04-05 << current version
# v1.4.1_2022-03-08
# v1.4.0_2022-02-25
# v1.3.0_2022-01-27
# v1.2.0_2021-12-15
# v1.1.0_2021-11-02
# v1.0.0_2021-07-30

# Upgrade
az arcdata dc upgrade --desired-version 'v1.5.0_2022-04-05' --name 'arc-dc' --resource-group $resourceGroup

```

---

### Test PITRs

1. Connect to Primary endpoint via SSMS: `172.30.93.188,31433`

2. Create Database & Table

```sql
-- Create DB
CREATE DATABASE raki_pitr_test;
GO

USE raki_pitr_test;
GO 

CREATE TABLE table1 (ID int, value nvarchar(10))
GO

INSERT INTO table1 VALUES (1, 'demo1')
INSERT INTO table1 VALUES (2, 'demo2')

SELECT * FROM table1;
-- Data is there

-- Get GUID
SELECT drs.recovery_fork_guid, dbs.name, dbs.state
FROM sys.database_recovery_status drs
JOIN sys.databases dbs
ON drs.database_id = dbs.database_id
WHERE dbs.[state] = 0
AND dbs.name = 'raki_pitr_test'

-- 4FAF3DAB-AF8F-4EDE-9000-41A2344DA82F

-- Check if backups are taken by PITR
SELECT s.database_name,
       CASE s.[type]
              WHEN 'D' THEN 'Full'
              WHEN 'I' THEN 'Differential'
              WHEN 'L' THEN 'Transaction Log'
       END AS backuptype,
       s.first_lsn,
       s.last_lsn,
       s.database_backup_lsn,
       s.checkpoint_lsn,
       s.recovery_model,
       *
FROM   msdb..backupset s
WHERE  s.database_name = 'raki_pitr_test' ORDER BY s.backup_finish_date DESC
```

3. Ensure backups are present in Pod
```bash
kubectl exec -it sql-gp-1-0 -c arc-sqlmi -n arc -- /bin/sh

export backups='4FAF3DAB-AF8F-4EDE-9000-41A2344DA82F'
backups=$(echo $backups | tr '[:upper:]' '[:lower:]')
cd /var/opt/mssql/backups/current/$backups

# We see our DB backups
ls -la
# total 3576
# drwxrwxr-x.  2 1000700001 1000700001    4096 Mar 23 22:08 .
# drwxrwxr-x. 11 1000700001 1000700001    4096 Mar 23 22:02 ..
# -rw-rw----.  1 1000700001 1000700001 3198976 Mar 23 22:01 full-20220323220148-fb6e2eb7-d366-405b-a0dd-8e8643141990.bak
# -rw-rw-r--.  1 1000700001 1000700001     872 Mar 23 22:02 full-20220323220148-fb6e2eb7-d366-405b-a0dd-8e8643141990.json
# -rw-rw----.  1 1000700001 1000700001  307200 Mar 23 22:02 log-20220323220248-fde5a5ed-0480-4b52-933b-47faac67b871.bak
# -rw-rw-r--.  1 1000700001 1000700001     871 Mar 23 22:02 log-20220323220248-fde5a5ed-0480-4b52-933b-47faac67b871.json
# -rw-rw----.  1 1000700001 1000700001  110592 Mar 23 22:08 log-20220323220818-83b962ed-fdec-46fd-b02b-52f03db506c9.bak
# -rw-rw-r--.  1 1000700001 1000700001     870 Mar 23 22:08 log-20220323220818-83b962ed-fdec-46fd-b02b-52f03db506c9.json

# Let's pick a restore time
cat log-20220410223622-b8a3bdf4-be96-4f35-9c27-d45da92acba0.json
# {
#   "databaseName": "raki_pitr_test",
#   "uniqueDatabaseId": "4faf3dab-af8f-4ede-9000-41a2344da82f",
#   "createdDateTime": "2022-04-10T22:36:22.3022144Z",
#   "backupFilePath": "current/4faf3dab-af8f-4ede-9000-41a2344da82f/log-20220410223622-b8a3bdf4-be96-4f35-9c27-d45da92acba0.bak",
#   "backupStatus": 1,
#   "backupId": "b8a3bdf4-be96-4f35-9c27-d45da92acba0",
#   "backupStartDate": "2022-04-10T22:36:23Z",
#   "backupFinishDate": "2022-04-10T22:36:23Z",
#   "lastValidRestoreTime": "2022-04-10T22:30:53Z",
#   "firstLsn": "38000000100800001",
#   "lastLsn": "38000000110400001",
#   "checkpointLsn": "38000000101600002",
#   "databaseBackupLsn": "38000000040800001",
#   "backupType": 1,
#   "familyGuid": "4faf3dab-af8f-4ede-9000-41a2344da82f",
#   "backupSetGuid": "a258a0e2-0f34-4bbc-ab33-5e580dac8194",
#   "compatibilityLevel": 160,
#   "isDamaged": false,
#   "uncompressedBackupSize": 81920
# }
```

4. Apply (in)correct restore task

```bash
# Correct date
cat <<EOF | kubectl create -f -
apiVersion: tasks.sql.arcdata.microsoft.com/v1
kind: SqlManagedInstanceRestoreTask
metadata:
  name: sql-restore-raki-correct
  namespace: arc
spec:
  source:
    name: sql-gp-1
    database: raki_pitr_test
  restorePoint: "2022-04-10T22:30:53Z"
  destination:
    name: sql-gp-1
    database: raki_pitr_test_restore
EOF

# sql-restore-raki-correct   Completed   16s

# Incorrect date
cat <<EOF | kubectl create -f -
apiVersion: tasks.sql.arcdata.microsoft.com/v1
kind: SqlManagedInstanceRestoreTask
metadata:
  name: sql-restore-raki-incorrect
  namespace: arc
spec:
  source:
    name: sql-gp-1
    database: raki_pitr_test
  restorePoint: "1990-04-10T22:30:53Z"
  destination:
    name: sql-gp-1
    database: raki_pitr_test_restore_2
EOF

# sql-restore-raki-incorrect   Failed      25s
# Status:
#   Earliest Restore Time:  2022-04-10T22:30:34.000000Z
#   Last Update Time:       2022-04-10T22:44:59.957682Z
#   Latest Restore Time:    2022-04-10T22:36:23.000000Z
#   Message:                '1990-04-10T22:30:53.0000000Z' is outside the range of available backups from '2022-04-10T22:30:34.0000000Z' to '2022-04-10T22:36:23.0000000Z' (Parameter 'RestoreTime')
#   Observed Generation:    1
#   State:                  Failed
# Events:                   <none>
```

---

# OTEL

```bash
# Get Secrets
kubectl get secret controller-db-rw-secret -n arc -o json | jq -r '.data.password' | base64 -d
kubectl get secret controller-db-rw-secret -n arc -o json | jq -r '.data.username' | base64 -d
kubectl get secret controller-db-data-encryption-key-secret -n arc -o json | jq -r '.data.encryptionPassword' | base64 -d
```

| Tech       | Expose endpoint                                                         | Endpoint                 | Credentials                                        | Purpose                  |
| ---------- | ----------------------------------------------------------------------- | ------------------------ | -------------------------------------------------- | ------------------------ |
| FSM        | `kubectl port-forward service/controldb-svc -n arc 1433:1433`           | `127.0.0.1,1433`         | controldb-rw-user:V2PtzVq9iW8pnJ-qi33GRqw8aumYmxPV | ControllerDB             |

### Expose ControlDB as a `LoadBalancer`
```bash
cat <<EOF | kubectl create -f -
apiVersion: v1
kind: Service
metadata:
  name: controldb-external-svc
  namespace: arc
spec:
  type: LoadBalancer
  selector:
    ARC_NAMESPACE: arc
    app: controldb
    plane: control
    role: controldb
  ports:
  - name: database-port
    port: 1433
    protocol: TCP
    targetPort: 1433
EOF

NAME                      TYPE           CLUSTER-IP       EXTERNAL-IP      PORT(S)                                       AGE
controldb-external-svc    LoadBalancer   10.152.183.23    172.31.147.204   1433:31385/TCP                                6s
```

### Grab certs for OTEL repo

Run `/workspaces/microk8s-arc/kubernetes/otel/pull-certs.sh`

Copy to `C:\Users\mdrrahman\Documents\GitHub\otel-hackathon\Arc-otel-experiment\certificates`.

### Inject OTEL File Delivery

Run:
```powershell
cd C:\Users\mdrrahman\Documents\GitHub\otel-hackathon
code -r Arc-file-delivery-injector
```
Run the dotnet App `C:\Users\mdrrahman\Documents\GitHub\otel-hackathon\Arc-file-delivery-injector` via `dotnet run` to inject the file Delivery.

> Make sure to localize to IP of Controller DB and Password and encryptionKey in the dotnet!

```bash
dotnet clean
dotnet build
dotnet run
```

### OTEL demo
* Create Kafka for both namespaces
* Create OTEL collector and agent

### Reboot SQL MI to fire Fluentbit

```bash
k delete pod sql-gp-1-0 -n arc --grace-period=0 --force
```

Tail fluentbit in case something breaks.

--- 
# Active Directory VM setup on Hyper-V

### First time create VM with ISO and Install Windows manually
```powershell
New-VM -Name 'dc-1' -MemoryStartupBytes 4096MB -Path 'C:\HyperV\VMs'
New-VHD -Path 'C:\HyperV\Disks\ws2022.dc_1.vhdx' -SizeBytes 60GB -Dynamic
Add-VMHardDiskDrive -VMName 'dc-1' -Path 'C:\HyperV\Disks\ws2022.dc_1.vhdx'
Set-VMDvdDrive -VMName 'dc-1' -ControllerNumber 1 -Path 'D:\iso\en-us_windows_server_2022_updated_april_2022_x64_dvd_d428acee.iso'
Set-VMMemory -VMName 'dc-1' -DynamicMemoryEnabled $false -Priority 100
Set-VMProcessor -VMName 'dc-1' -Count 2
Get-VM 'dc-1' | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName "Default Switch"
Set-VM -Name 'dc-1' -CheckpointType Disabled

Get-VM 'dc-1'

Start-VM –Name 'dc-1'

# ---> Go inside and install Windows using Key etc.

# Rename machine
$password = ConvertTo-SecureString 'acntorPRESTO!' -AsPlainText -Force
$localhostAdminUser = New-Object System.Management.Automation.PSCredential ('Administrator', $password)
Rename-Computer -NewName "dc-1" -LocalCredential $localhostAdminUser -Restart

# ---> Shut down
# ---> Take VHD backup once you RDP into Windows succesfully
```
`Snapshot: ws2022.dc_1_fresh_activated.vhdx`

### Upgrade to a Domain Controller
```powershell
# Configure the Domain Controller
$domainName = 'fg.contoso.com'
$domainAdminPassword = "acntorPRESTO!"
$secureDomainAdminPassword = $domainAdminPassword | ConvertTo-SecureString -AsPlainText -Force

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Create Active Directory Forest
Install-ADDSForest `
    -DomainName "$domainName" `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -DomainMode "7" `
    -DomainNetbiosName $domainName.Split('.')[0].ToUpper() `
    -ForestMode "7" `
    -InstallDns:$true `
    -LogPath "C:\Windows\NTDS" `
    -NoRebootOnCompletion:$false `
    -SysvolPath "C:\Windows\SYSVOL" `
    -Force:$true `
    -SafeModeAdministratorPassword $secureDomainAdminPassword
```
> Turn off `Enhanced Session` after reboot when it gets stuck at `please wait for gpsvc`!
> Will take a couple mins to get past `Applying computer settings` screen - Win 2022 will go through with it

```PowerShell
# Turn off enhanced session
Set-VMhost -EnableEnhancedSessionMode $False
```

After the reboot, we can RDP as our Domain Admin `FG\Administrator`:
![1](_images\1.png)

> Internet etc works!

### Do a bunch of peripheral stuff
```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Install chocolatey
iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

# Install apps
$chocolateyAppList = 'grep,ssms'

$appsToInstall = $chocolateyAppList -split "," | foreach { "$($_.Trim())" }

foreach ($app in $appsToInstall)
{
    Write-Host "Installing $app"
    & choco install $app /y -Force| Write-Output
}
```
`Snapshot: ws2022.dc_1_fresh_activated_domain_on.vhdx`

### Utility functions

```powershell
# Blow away VM:
Stop-VM –Name 'dc-1'
Remove-VM -Name 'dc-1' -Force
Remove-Item 'C:\HyperV\Disks\ws2022.dc_1.vhdx'
Remove-Item 'C:\HyperV\VMs\dc-1' -Recurse -Confirm:$false

# Restart Hyper-V if needed with a stuck VM
Stop-Service vmms -Force
Start-Service vmms

# Get VM IP Address from Hyper-V
get-vm  | Select -ExpandProperty Networkadapters  | Select VMName, IPAddresses

# VMName    IPAddresses
# ------    -----------
# dc-1      {172.22.59.82, fe80::d41b:4054:bc40:ba3d}
```

⭐ Create VM from backed up VHDx:
```powershell
# Turn on enhanced session
Set-VMhost -EnableEnhancedSessionMode $True

Copy-Item -Path 'C:\HyperV\VHD_baks\ws2022.dc_1_fresh_activated_domain_on.vhdx' -Destination 'C:\HyperV\Disks\ws2022.dc_1.vhdx' -PassThru
Start-Sleep -s 5
New-VM -Name 'dc-1' -MemoryStartupBytes 4096MB -Path 'C:\HyperV\VMs'# -Generation 1
Add-VMHardDiskDrive -VMName 'dc-1' -Path 'C:\HyperV\Disks\ws2022.dc_1.vhdx'
Set-VMMemory -VMName 'dc-1' -DynamicMemoryEnabled $false -Priority 100
Set-VMProcessor -VMName 'dc-1' -Count 2
Get-VM 'dc-1' | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName "Default Switch"
Set-VM -Name 'dc-1' -CheckpointType Disabled

Get-VM 'dc-1'

Start-VM –Name 'dc-1'

# Username: Administrator
# Password: acntorPRESTO!
```
⭐ Set Static IP address - the same one that we get with DHCP. This is for Domain Controller purposes.

> This seems to reset every reboot
```powershell
$IP = (Get-NetIPAddress | Where-Object {$_.AddressState -eq "Preferred" -and $_.ValidLifetime -lt "24:00:00"}).IPAddress
$MaskBits = 22 # This means subnet mask = 255.255.252.0
$Gateway = (Get-NetIPConfiguration | Foreach IPv4DefaultGateway | Select NextHop)."NextHop"
$DNS = "127.0.0.1"
$IPType = "IPv4"
# Retrieve the network adapter that you want to configure
$adapter = Get-NetAdapter | ? {$_.Status -eq "up"}
# Remove any existing IP, gateway from our ipv4 adapter
If (($adapter | Get-NetIPConfiguration).IPv4Address.IPAddress) {
 $adapter | Remove-NetIPAddress -AddressFamily $IPType -Confirm:$false
}
If (($adapter | Get-NetIPConfiguration).Ipv4DefaultGateway) {
 $adapter | Remove-NetRoute -AddressFamily $IPType -Confirm:$false
}
 # Configure the IP address and default gateway
$adapter | New-NetIPAddress `
 -AddressFamily $IPType `
 -IPAddress $IP `
 -PrefixLength $MaskBits `
 -DefaultGateway $Gateway
# Configure the DNS client server IP addresses
$adapter | Set-DnsClientServerAddress -ServerAddresses $DNS
```
---

## Deploy Arc twice: Primary, Secondary

```bash
export ns='secondary' #primary

# Create with the Microk8s profile
az arcdata dc create --path './custom' \
                     --k8s-namespace $ns \
                     --name $arcDcName \
                     --subscription $subscriptionId \
                     --resource-group $resourceGroup \
                     --location $azureLocation \
                     --connectivity-mode indirect \
                     --use-k8s

# Monitor Data Controller
watch -n 20 kubectl get datacontroller -n $ns

# Monitor pods
watch -n 10 kubectl get pods -n $ns
```
---
# K8s API server

## References
* ⭐ API Docs: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.24

## Playaround

### Bash
```bash
# https://kubernetes.io/docs/tasks/extend-kubernetes/http-proxy-access-api/
# This creates a proxy to Kubernetes API Server
kubectl proxy --port=8080

# This works in this container, and also in Edge on my laptop thanks to port-forward
curl http://localhost:8080
# {
#   "paths": [
#     ...
#     "/apis/apps",
#     "/apis/apps/v1",
#     "/apis/authentication.k8s.io",
#     "/apis/authentication.k8s.io/v1",
#     "/apis/authorization.k8s.io",
#     ...

# Get all pods in kube-system
curl http://localhost:8080/api/v1/namespaces/kube-system/pods

# Logs from CoreDNS
curl http://localhost:8080/api/v1/namespaces/kube-system/pods/coredns-7f9c69c78c-tcdbv/log
# .:53
# [INFO] plugin/reload: Running configuration MD5 = be0f52d3c13480652e0c73672f2fa263
# CoreDNS-1.8.0
# linux/amd64, go1.15.3, 054c9ae
# W0524 14:55:24.338270       1 reflector.go:424] pkg/mod/k8s.io/client-go@v0.19.2/tools/cache/reflector.go:156: watch of *v1.Endpoints ended with: very short watch: pkg/mod/k8s.io/client-go@v0.19.2/tools/cache/reflector.go:156: Unexpected watch close - watch lasted less than a second and no items received

# Get a list of all APIs
curl http://localhost:8080/apis

# Call a CRD
curl http://localhost:8080/apis/crd.projectcalico.org
curl http://localhost:8080/apis/crd.projectcalico.org/v1

# Call non-ns resource like Nodes and PVs
curl http://localhost:8080/api/v1/nodes
```
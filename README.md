# microk8s for Arc
Environment to deploy Arc Data Services in a fresh Microk8s Cluster.

## Microk8s deployment

Run these in local **PowerShell** to spin up via Multipass:
```PowerShell
# Delete old one (if any)
multipass list
multipass delete microk8s-vm
multipass purge

# Single node K8s cluster
# Latest releases: https://microk8s.io/docs/release-notes
microk8s install "--cpu=8" "--mem=32" "--disk=50" "--channel=1.22/stable" -y

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
# microk8s-vm   Ready    <none>   75s   v1.22.6-3+7ab10db7034594   172.27.229.208   <none>        Ubuntu 18.04.6 LTS   4.15.0-169-generic   containerd://1.5.2

# Enable features needed for arc
microk8s enable dns storage metallb ingress
# Enter CIDR for MetalLB: 172.27.229.215-172.27.229.225

# Access via kubectl in this container
$DIR = "C:\Users\mdrrahman\Documents\GitHub\microk8s-arc\microk8s"
microk8s config view > $DIR\config # Export kubeconfig
```

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

## Arc deployment - latest release

```bash
cd kubernetes

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

# Monitor pods in arc namespace in another window
watch -n 20 kubectl get pods -n arc

#########################################
# Create data controller in indirect mode
#########################################
# Create custom profile for Microk8s - ok to use AKS since we have LoadBalancer
az arcdata dc config init --source azure-arc-aks-default-storage --path custom --force

# Just need to replace storageClass
sed -i -e 's/default/microk8s-hostpath/g' custom/control.json

# Create with the AKS profile
az arcdata dc create --path './custom' \
                     --k8s-namespace arc \
                     --name $arcDcName \
                     --subscription $subscriptionId \
                     --resource-group $resourceGroup \
                     --location $azureLocation \
                     --connectivity-mode indirect \
                     --use-k8s

# Deploying data controller
# NOTE: Data controller creation can take a significant amount of time depending on
# configuration, network speed, and the number of nodes in the cluster.

# Monitor Data Controller
watch -n 20 kubectl get datacontroller -n arc

# Create SQL MI
kubectl apply -f sql-mi/sql-gp-1.yaml

# And we can get the connectivity endpoints
kubectl get sqlmi sql-gp-1 -n arc -o json | jq -r ".status.endpoints"
{
  "logSearchDashboard": "https://172.27.229.217:5601/app/kibana#/discover?_a=(query:(language:kuery,query:'custom_resource_name:sql-gp-1'))",
  "metricsDashboard": "https://172.27.229.216:3000/d/40q72HnGk/sql-managed-instance-metrics?var-hostname=sql-gp-1-0",
  "mirroring": "172.27.229.218:5022",
  "primary": "172.27.229.218,31433"
}
```

---

## Tear down cluster

Run in PowerShell:
```PowerShell
microk8s stop
multipass delete microk8s-vm
multipass purge
```
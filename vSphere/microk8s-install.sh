#!/bin/bash
export adminUsername='boor'
echo "###########################################################################"
echo "Installing snap, Docker and Microk8s..." 
echo "###########################################################################"
sudo apt-get update
sudo apt install snapd
# Docker is needed for VSContainer
sudo snap install docker
sudo snap install microk8s --classic --channel=1.24/stable
sudo snap alias microk8s.kubectl kubectl
sudo microk8s status --wait-ready
echo "###########################################################################"
echo "Microk8s specific configurations..." 
echo "###########################################################################"
sudo microk8s enable dns storage dashboard ingress rbac registry:size=100Gi
# Wait until Microk8s features are done enabling
sleep 10
# Enable --allow-privileged for Arc Extensions deployments
# See: https://github.com/ubuntu/microk8s/issues/749
sudo bash -c 'echo "--allow-privileged" >> /var/snap/microk8s/current/args/kube-apiserver'
sudo microk8s stop
sleep 5
sudo microk8s start
echo "###########################################################################"
echo "Export kubeconfig..." 
echo "###########################################################################"
# Set Kubeconfig - export from microk8s
kubeconfigPath="/home/${adminUsername}/.kube"
mkdir -p $kubeconfigPath
sudo chown -R $adminUsername $kubeconfigPath
sudo microk8s config view > "$kubeconfigPath/config"
# Docker list all network and their IP addresses
docker network ls --format '{{.Name}}: {{.Driver}}' | while read -r line; do
  echo "$line"
  docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${line%%:*}"
done

# Get Azure-cli version 2.28
apt-get install -y azure-cli && az --version
sudo yum install -y zsh git make
sudo yum install iptables-services -y
sudo systemctl enable iptables
sudo systemctl start iptables

mkdir -p ./kubebuilder/bin && \
    curl -L https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-1.30.0-linux-arm64.tar.gz -o kubebuilder-tools.tar.gz && \
    tar -C ./kubebuilder --strip-components=1 -zvxf kubebuilder-tools.tar.gz && \
    rm kubebuilder-tools.tar.gz

curl -L "https://dl.k8s.io/v1.30.0/bin/linux/arm64/kubelet" -o kubebuilder/bin/kubelet

echo "Generating service account key pair..." && \
openssl genrsa -out /tmp/sa.key 2048 && \
openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub

echo "Generating token file..." && \
    TOKEN="1234567890" && \
    echo "${TOKEN},admin,admin,system:masters" > /tmp/token.csv

echo "Setting up kubeconfig..."
sudo kubebuilder/bin/kubectl config set-credentials test-user --token=1234567890
sudo kubebuilder/bin/kubectl config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
sudo kubebuilder/bin/kubectl config set-context test-context --cluster=test-env --user=test-user --namespace=default 
sudo kubebuilder/bin/kubectl config use-context test-context

HOST_IP=$(hostname -I | awk '{print $1}')
echo "HOST_IP: ${HOST_IP}"

echo "Starting etcd..."
kubebuilder/bin/etcd \
    --advertise-client-urls http://$HOST_IP:2379 \
    --listen-client-urls http://0.0.0.0:2379 \
    --data-dir ./etcd \
    --listen-peer-urls http://0.0.0.0:2380 \
    --initial-cluster default=http://$HOST_IP:2380 \
    --initial-advertise-peer-urls http://$HOST_IP:2380 \
    --initial-cluster-state new \
    --initial-cluster-token test-token &

echo "Starting kube-apiserver..."
sudo kubebuilder/bin/kube-apiserver \
    --etcd-servers=http://$HOST_IP:2379 \
    --service-cluster-ip-range=10.0.0.0/24 \
    --bind-address=0.0.0.0 \
    --secure-port=6443 \
    --advertise-address=$HOST_IP \
    --authorization-mode=AlwaysAllow \
    --token-auth-file=/tmp/token.csv \
    --enable-priority-and-fairness=false \
    --allow-privileged=true \
    --profiling=false \
    --storage-backend=etcd3 \
    --storage-media-type=application/json \
    --v=0 \
    --service-account-issuer=https://kubernetes.default.svc.cluster.local \
    --service-account-key-file=/tmp/sa.pub \
    --service-account-signing-key-file=/tmp/sa.key &

echo "Installing containerd..."
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d

echo "Downloading containerd..."
wget https://github.com/containerd/containerd/releases/download/v2.1.2/containerd-static-2.1.2-linux-arm64.tar.gz

echo "Downloading CNI plugins..."
sudo curl -L "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.arm64" -o /opt/cni/bin/runc

echo "Downloading kube-controller-manager and kube-scheduler ..."
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/arm64/kube-controller-manager" -o kubebuilder/bin/kube-controller-manager
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/arm64/kube-scheduler" -o kubebuilder/bin/kube-scheduler

echo "Extract and install components ..."
sudo tar zxf containerd-static-2.1.2-linux-arm64.tar.gz -C /opt/cni/
sudo tar zxf cni-plugins-linux-arm64-v1.6.2.tgz -C /opt/cni/bin/


echo "Configuring CNI..."
cat <<EOF > 10-mynet.conf
{
    "cniVersion": "0.3.1",
    "name": "mynet",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "subnet": "10.22.0.0/16",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ]
    }
}
EOF
sudo mv 10-mynet.conf /etc/cni/net.d/10-mynet.conf

echo "Setting permissions..."
sudo chmod +x /opt/cni/bin/runc
sudo chmod +x kubebuilder/bin/kube-controller-manager
sudo chmod +x kubebuilder/bin/kubelet 
sudo chmod +x kubebuilder/bin/kube-scheduler


echo "Configuring containerd"
sudo mkdir -p /etc/containerd/
cat <<EOF > config.toml
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
        runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime.options]
          SystemdCgroup = true
EOF
sudo mv config.toml /etc/containerd/config.toml


echo "Start Remaining Components"

export PATH=$PATH:/opt/cni/bin:kubebuilder/bin
echo "Starting containerd..."
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml &

echo "Starting kube-scheduler..."
sudo kubebuilder/bin/kube-scheduler \
    --kubeconfig=/root/.kube/config \
    --leader-elect=false \
    --v=2 \
    --bind-address=0.0.0.0 &


echo "Creating kubelet directories..."
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/log/kubernetes

echo "Generating CA certificate for kubelet..."
openssl genrsa -out /tmp/ca.key 2048
openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
sudo cp /tmp/ca.crt /var/lib/kubelet/ca.crt

cat << EOF | sudo tee /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubelet/ca.crt"
authorization:
  mode: AlwaysAllow
clusterDomain: "cluster.local"
clusterDNS:
  - "10.0.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
failSwapOn: false
seccompDefault: true
serverTLSBootstrap: true
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
staticPodPath: "/etc/kubernetes/manifests"
EOF

echo "Setting up kubelet kubeconfig"
sudo cp /root/.kube/config /var/lib/kubelet/kubeconfig
export KUBECONFIG=~/.kube/config
cp /tmp/sa.pub /tmp/ca.crt

echo "Creating service account and configmap..."
sudo kubebuilder/bin/kubectl create sa default
sudo kubebuilder/bin/kubectl create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt -n default

echo "Starting kubelet..."
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet \
    --kubeconfig=/var/lib/kubelet/kubeconfig \
    --config=/var/lib/kubelet/config.yaml \
    --root-dir=/var/lib/kubelet \
    --cert-dir=/var/lib/kubelet/pki \
    --hostname-override=$(hostname)\
    --pod-infra-container-image=registry.k8s.io/pause:3.10 \
    --node-ip=$HOST_IP \
    --cgroup-driver=cgroupfs \
    --max-pods=4  \
    --v=1 &

echo "Starting kube-controller-manager..."
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kube-controller-manager \
    --kubeconfig=/var/lib/kubelet/kubeconfig \
    --leader-elect=false \
    --allocate-node-cidrs=true \
    --cluster-cidr=10.0.0.0/16 \
    --service-cluster-ip-range=10.0.0.0/24 \
    --cluster-name=kubernetes \
    --root-ca-file=/var/lib/kubelet/ca.crt \
    --service-account-private-key-file=/tmp/sa.key \
    --use-service-account-credentials=true \
    --v=2 &
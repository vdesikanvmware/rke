#!/bin/bash
if [ -z "$1" ]; then
  version="1.29"
  avi_ip=$(echo "MTAuMTYwLjE0My43MQ==" | base64 -d)
  avi_user=$(echo "YWRtaW4=" | base64 -d)
  avi_password=$(echo "Vk1XYXJlMSE=" | base64 -d)
  echo "===Using default version (1.29 and default AVI controller)==="
elif [ $1 = "menu" ]; then
  echo "Enter kubernetes Version (E.g 1.29)"
  read version
  echo "Enter AVI Controller IP"
  read avi_ip
  echo "Enter AVI Controller admin username"
  read avi_user
  echo "Enter AVI Controller password"
  read avi_password
  echo "===Using the values passed==="
else
  echo "Usage: ./rke-setup.sh  or ./rke-setup.sh menu"
  exit
fi

if [ $version  = "1.28" ]; then
    export VER="v1.28.15+rke2r1"
elif [ $version = "1.29" ]; then
    export VER="v1.29.12+rke2r1"
elif [ $version = "1.30" ]; then
    export VER="v1.30.8+rke2r1"
elif [ $version = "1.31" ]; then
    export VER="v1.31.4+rke2r1"
fi

echo "===Downloading artifacts==="
mkdir -p /root/rke2-artifacts && cd /root/rke2-artifacts/
curl -OLs https://github.com/rancher/rke2/releases/download/$VER/rke2-images.linux-amd64.tar.zst
curl -OLs https://github.com/rancher/rke2/releases/download/$VER/rke2.linux-amd64.tar.gz
curl -OLs https://github.com/rancher/rke2/releases/download/$VER/sha256sum-amd64.txt
curl -sfL https://get.rke2.io --output install.sh

echo "===disabling etcd==="
mkdir -p /etc/rancher/rke2/
echo "disable-etcd: true" > /etc/rancher/rke2/config.yaml

echo "===Install RKE2==="
INSTALL_RKE2_ARTIFACT_PATH=/root/rke2-artifacts sh install.sh

echo "===Enable RKE2 service==="
systemctl enable rke2-server.service

echo "===Start RKE2 service==="
systemctl start rke2-server.service

echo "===Verify RKE service is active==="
sleep 60
active=$(systemctl status rke2-server.service | grep -Po active)
running=$(systemctl status rke2-server.service | grep -Po running)
if [[ $active = "active" ]] && [[ $running = "running" ]]; then
  echo "RKE service is active & running"
else
  echo "RKE service is not up, please debug."
  exit
fi

echo "===Update IP in kubeconfig==="
ext_ip=$(hostname  -I | cut -f1 -d' ')
sed -i "s|127.0.0.1|$ext_ip|g" /etc/rancher/rke2/rke2.yaml
mkdir -p /root/.kube
cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
export KUBECONFIG=/root/.kube/config
echo "Kubeconfig is $KUBECONFIG"

echo "===Install AVI Kubernetes Operator==="
hn=$(hostname)
cat > /root/avi_values.yaml <<EOF
NetworkSettings:
  vipNetworkList:
   - networkName: "user-vlan02-3183"
AKOSettings:
  cniPlugin: "canal"
  clusterName: $hn
L7Settings:
  defaultIngController: "true"
  serviceType: NodePort
EOF

kubectl create ns avi-system
helm install --generate-name oci://projects.packages.broadcom.com/ako/helm-charts/ako  -f /root/avi_values.yaml  --set ControllerSettings.controllerHost=$avi_ip --set avicredentials.username=$avi_user --set avicredentials.password=$avi_password --set AKOSettings.primaryInstance=true --namespace=avi-system

echo "===Waiting for AKO pod to be in running state==="
ako_pod=$(kubectl get pods -n avi-system --kubeconfig=$KUBECONFIG | grep -Po Running)
while [ -z "$ako_pod" ];
do
  ako_pod=$(kubectl get pods -n avi-system --kubeconfig=$KUBECONFIG | grep -Po Running)
  sleep 10
  echo "waiting"
done
echo "AKO pod is running"

echo "===Configure local path storage==="
cat > /root/local-path-storage.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-path-provisioner-service-account
  namespace: local-path-storage

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: local-path-provisioner-role
  namespace: local-path-storage
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-path-provisioner-role
rules:
  - apiGroups: [""]
    resources: ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: local-path-provisioner-bind
  namespace: local-path-storage
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-path-provisioner-bind
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: local-path-provisioner-role
subjects:
  - kind: ServiceAccount
    name: local-path-provisioner-service-account
    namespace: local-path-storage

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-path-provisioner
  namespace: local-path-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-path-provisioner
  template:
    metadata:
      labels:
        app: local-path-provisioner
    spec:
      serviceAccountName: local-path-provisioner-service-account
      containers:
        - name: local-path-provisioner
          image: quay.io/vdesikanvmware/local-path-provisioner
          imagePullPolicy: IfNotPresent
          command:
            - local-path-provisioner
            - --debug
            - start
            - --config
            - /etc/config/config.json
          volumeMounts:
            - name: config-volume
              mountPath: /etc/config/
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: CONFIG_MOUNT_PATH
              value: /etc/config/
      volumes:
        - name: config-volume
          configMap:
            name: local-path-config

---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete

---
kind: ConfigMap
apiVersion: v1
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |-
    {
            "nodePathMap":[
            {
                    "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
                    "paths":["/opt/local-path-provisioner"]
            }
            ]
    }
  setup: |-
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |-
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |-
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      priorityClassName: system-node-critical
      tolerations:
        - key: node.kubernetes.io/disk-pressure
          operator: Exists
          effect: NoSchedule
      containers:
      - name: helper-pod
        image: quay.io/vdesikanvmware/busybox
        imagePullPolicy: IfNotPresent
EOF

kubectl apply -f /root/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "===Verify local-path-storage is available and is the default one==="
sleep 60
lp=$(kubectl get sc -A --kubeconfig=$KUBECONFIG  | grep -Po rancher.io/local-path)
df=$(kubectl get sc -A --kubeconfig=$KUBECONFIG  | grep -Po default)
if [[ $lp = "rancher.io/local-path" ]] && [[ $df = "default" ]]; then
  echo "local-path-storage is available and is the default one"
else
  echo "local-path-storage setup failed, please debug."
  exit
fi

echo "===Check and wait till all pods are up and running==="
pod_status=$(kubectl get pods -A | grep -Ev 'Running|Completed' | grep -v NAMESPACE)
while [ ! -z $pod_status];
do
  sleep 10
  pod_status=$(kubectl get pods -A | grep -Ev 'Running|Completed' | grep -v NAMESPACE)
done
echo "RKE setup is completed"

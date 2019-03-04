#!/bin/sh

# 接收传入参数
REGION=$1
USERNAME=$2
PASSWD=$3
KUBEVER=$4
IP=$5
SP=$6
PORT_RAND=$7
UUID=$8
SS_PWD=$9
BBR=$10
DOMAIN=$11
EMAIL=$12
WEBSOCKET_PATH=$13
SS_WEBSOCKET_PATH=$14

# 安装 IBM Cloud CLI
echo -e '\nDownload IBM Cloud CLI ...'
curl -Lo IBM_Cloud_CLI_amd64.tar.gz https://clis.ng.bluemix.net/download/bluemix-cli/latest/linux64
echo -e '\nInstall IBM Cloud CLI ...'
tar -zxf IBM_Cloud_CLI_amd64.tar.gz
cd Bluemix_CLI
sh ./install_bluemix_cli
ibmcloud config --usage-stats-collect false

#登录到 IBM Cloud CLI
ibmcloud  login -a https://api.${REGION}.bluemix.net -u $USERNAME -p $PASSWD
(echo 1; echo 1) | ibmcloud target --cf  #Target Cloud Foundry org/space.

# 安装 IBM Cloud CLI 插件
echo -e '\nInstall IBM Cloud CLI plugins ...'
ibmcloud plugin install container-service -r Bluemix
ibmcloud plugin install container-registry -r Bluemix
ibmcloud ks init

# 安装 kubectl
echo -e '\nDownload kubectl ...'
curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/${KUBEVER}/bin/linux/amd64/kubectl
echo -e '\nInstall kubectl ...'
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl
echo

# 将 IBM Cloud CLI 配置为运行 kubectl
echo -e '\nConfigurate IBM Cloud CLI to run kubectl ...'
$(ibmcloud ks cluster-config $(ibmcloud ks clusters -s | grep 'normal' | awk '{print $1}') --export -s)
echo -e '\nKubectl version:'
echo
kubectl version  --short

# 启动 Docker
echo -e '\nStart Docker ...'
dockerd >/dev/null 2>&1 &
sleep 3
docker -v

# 初始化 IBM 容器（映像）注册表
echo -e '\nInitiate IBM Cloud container registry ...'
ibmcloud  cr login
for name in $(ibmcloud  cr namespace-list | grep del_); do (echo y) | ibmcloud  cr namespace-rm $name; done
NS=del_$(openssl rand -base64 16 | md5sum | head -c16)
ibmcloud  cr namespace-add $NS

# 准备 V2RAY 文件，配置 V2RAY 端口
mkdir -p /root/v2ray
cd /root/v2ray/
echo -e '\nDownload V2Ray ...'
curl -Lo v2ray.zip https://github.com/v2ray/dist/raw/master/v2ray-linux-64.zip
unzip -q v2ray.zip
chmod +x ./v2ray ./v2ctl

echo -e "\nConfigure the Inbound PORT of V2Ray server ..."
let V2RAY_PORT=$PORT_RAND+30000

# 构建与注册容器映像 V2RAY
echo -e '\nBuild and register the container image of "V2Ray" for VMess server ...'
echo -e "\nDownload V2Ray's config.json of VMess server ..."
curl -Lo config.json https://raw.githubusercontent.com/jogolor/V2RoIBMCKS/master/config-vmess.json
sed -i "s/{V2RAY_PORT}/$V2RAY_PORT/g" config.json
sed -i "s/{UUID_PWD}/$UUID/g" config.json
sed -i "s/{WEBSOCKET_PATH}/$WEBSOCKET_PATH/g" config.json

cat << _EOF_ > Dockerfile
FROM alpine:latest
RUN apk add --update --no-cache ca-certificates
ADD v2ray /usr/local/bin/
ADD v2ctl /usr/local/bin/
ADD geoip.dat /usr/local/bin/
ADD geosite.dat /usr/local/bin/
RUN mkdir /etc/v2ray
ADD config.json /etc/v2ray/
RUN mkdir /var/log/v2ray
CMD ["v2ray", "-config=/etc/v2ray/config.json"]
_EOF_

echo -e '\nBuild and push the container image of "V2Ray" ...'
ibmcloud cr build -t registry.${REGION}.bluemix.net/$NS/v2ray .

# 创建容器映像 V2RAY 的部署文件
echo -e '\nCreate the deployment file "v2ray.yaml" for the container image of "V2Ray" ...'
echo 'The image is from IBM Cloud container registry.'

cat << _EOF_ > v2ray.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v2ray
  labels:
    app: v2ray
spec:
  replicas: 1
  selector:
    matchLabels:
      app: v2ray
  template:
    metadata:
      name: v2ray
      labels:
        app: v2ray
    spec:
      containers:
      - name: v2ray
        image: registry.${REGION}.bluemix.net/${NS}/v2ray
        ports:
          - containerPort: $V2RAY_PORT
            protocol: TCP
          - containerPort: $V2RAY_PORT
            protocol: UDP
        resources:
          requests:
            memory: "300Mi"
            cpu: "150m"
          limits:
            memory: "500Mi"
            cpu: "300m"
      restartPolicy: Always
_EOF_

# 部署容器映像 V2RAY 到 IBM Cloud Kubernetes Service，获取 V2RAY_IP
echo -e '\nDeploy the container images of "V2Ray" to IBM Cloud Kubernetes Service ...'
kubectl create -f v2ray.yaml
kubectl expose deployment v2ray --name=v2ray-tcp-for-caddy --port=$V2RAY_PORT --protocol="TCP"
V2RAY_IP=$(kubectl get svc v2ray-tcp-for-caddy -o=custom-columns=IP:.spec.clusterIP | tail -n1)

# 构建与注册容器映像 V2RAY-SS
rm -f ./config.json # 清理容器映像 V2RAY 的 config.json
echo -e '\nBuild and register the container image of "V2Ray-SS" for Shadowsocks server ...'
echo -e "\nDownload V2Ray's config.json of Shadowsocks server ..."
curl -Lo config.json https://raw.githubusercontent.com/jogolor/V2RoIBMCKS/master/config-shadowsocks.json
sed -i "s/{V2RAY_PORT}/$V2RAY_PORT/g" config.json
sed -i "s/{UUID_PWD}/$SS_PWD/g" config.json
sed -i "s/{WEBSOCKET_PATH}/$SS_WEBSOCKET_PATH/g" config.json

echo -e '\nBuild and push the container image of "V2Ray-SS" ...'
ibmcloud cr build -t registry.${REGION}.bluemix.net/$NS/v2ray-ss . # 复用容器映像 V2RAY 的 Dockerfile

# 创建容器映像 V2RAY-SS 的部署文件
echo -e '\nCreate the deployment file "v2ray-ss.yaml" for the container image of "V2Ray-SS" ...'
echo 'The image is from IBM Cloud container registry.'

cat << _EOF_ > v2ray-ss.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v2ray-ss
  labels:
    app: v2ray-ss
spec:
  replicas: 1
  selector:
    matchLabels:
      app: v2ray-ss
  template:
    metadata:
      name: v2ray-ss
      labels:
        app: v2ray-ss
    spec:
      containers:
      - name: v2ray-ss
        image: registry.${REGION}.bluemix.net/${NS}/v2ray-ss
        ports:
          - containerPort: $V2RAY_PORT
            protocol: TCP
          - containerPort: $V2RAY_PORT
            protocol: UDP
        resources:
          requests:
            memory: "300Mi"
            cpu: "150m"
          limits:
            memory: "500Mi"
            cpu: "300m"
      restartPolicy: Always
_EOF_

# 部署容器映像 V2RAY-SS 到 IBM Cloud Kubernetes Service，获取 V2RAY_SS_IP
echo -e '\nDeploy the container images of "V2Ray-SS" to IBM Cloud Kubernetes Service ...'
kubectl create -f v2ray-ss.yaml
kubectl expose deployment v2ray-ss --name=v2ray-ss-tcp-for-caddy --port=$V2RAY_PORT --protocol="TCP"
V2RAY_SS_IP=$(kubectl get svc v2ray-ss-tcp-for-caddy -o=custom-columns=IP:.spec.clusterIP | tail -n1)

# 构建与注册容器映像 CADDY 
echo -e '\nBuild and register the container image of "Caddy" ...'
mkdir -p /root/caddy
cd /root/caddy/
echo -e '\nDownload Caddy ...'
curl -Lo caddy.tar.gz https://caddyserver.com/download/linux/amd64?license=personal
tar -zxf caddy.tar.gz
chmod +x ./caddy

cat << _EOF_ > Caddyfile
https://${DOMAIN} {
  log /var/log/caddy/access.log
  errors /var/log/caddy/error.log
  tls ${EMAIL}
  timeouts {
    read 60s
    write 30s
  }
  root /var/www
  proxy /${WEBSOCKET_PATH} ${V2RAY_IP}:${V2RAY_PORT} {
    websocket
    header_upstream -Origin
  }
  proxy /${SS_WEBSOCKET_PATH} ${V2RAY_SS_IP}:${V2RAY_PORT} {
    websocket
    header_upstream -Origin
  }
}
_EOF_

cat << _EOF_ > index.html
<html>
    <head>
        <meta http-equiv="content-type" content="text/html; charset=UTF-8" />
        <title>Being maintained</title>
    </head>
    <body style="background-color: #C2C2C2; color: #000000">
        <p style="padding: 15% 0 0 25%; font-size: 20px">
            This site is being maintained. It may take a while or a longer time.
        </p>
    </body>
</html>
_EOF_

cat << _EOF_ > Dockerfile
FROM alpine:latest
RUN apk add --update --no-cache openssh-client ca-certificates
ADD caddy /usr/local/bin/
RUN mkdir /etc/caddy
ADD Caddyfile /etc/caddy/
RUN mkdir /var/www
ADD index.html /var/www/
RUN mkdir /var/log/caddy
CMD ["caddy", "-conf=/etc/caddy/Caddyfile", "-agree"]
_EOF_

echo -e '\nBuild and push the container image of "Caddy" ...'
ibmcloud cr build -t registry.${REGION}.bluemix.net/$NS/caddy .

# 创建容器映像 CADDY 的部署文件
echo -e '\nCreate the deployment file "caddy.yaml" for the container image of "Caddy" ...'
echo 'The image is from IBM Cloud container registry.'

cat << _EOF_ > caddy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: caddy
  labels:
    app: caddy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: caddy
  template:
    metadata:
      name: caddy
      labels:
        app: caddy
    spec:
      containers:
      - name: caddy
        image: registry.${REGION}.bluemix.net/${NS}/caddy
        ports:
          - containerPort: $SP
            protocol: TCP
          - containerPort: $SP
            protocol: UDP
        resources:
          requests:
            memory: "500Mi"
            cpu: "300m"
          limits:
            memory: "800Mi"
            cpu: "500m"
      restartPolicy: Always
_EOF_

# 创建容器映像 BBR 的部署文件
echo -e '\nCreate the deployment file "bbr.yaml" for the container image of "BBR" ...'
echo 'The image is from hub.docker.com.'

cat << _EOF_ > bbr.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bbr
  labels:
    app: bbr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bbr
  template:
    metadata:
      name: bbr
      labels:
        app: bbr
    spec:
      containers:
      - name: bbr
        image: wuqz/lkl:latest
        env:
          - name: TARGET_HOST
            value: TARGET_IP
          - name: TARGET_PORT
            value: "$SP"
          - name: BIND_PORT
            value: "$SP"
        ports:
          - containerPort: $SP
            protocol: TCP
        resources:
          requests:
            memory: "500Mi"
            cpu: "300m"
          limits:
            memory: "800Mi"
            cpu: "500m"
        securityContext:
          privileged: true
      restartPolicy: Always
_EOF_

# 部署容器映像 CADDY & BBR 到 IBM Cloud Kubernetes Service
echo -e '\nDeploy the container image of "Caddy" to IBM Cloud Kubernetes Service ...'
kubectl create -f caddy.yaml
if $BBR; then
    kubectl expose deployment caddy --name=caddy-tcp-for-bbr --port=$SP --protocol="TCP"
    sed -i "s/TARGET_IP/$(kubectl get svc caddy-tcp-for-bbr -o=custom-columns=IP:.spec.clusterIP | tail -n1)/g" bbr.yaml
    echo -e '\nDeploy the container image of "BBR" to IBM Cloud Kubernetes Service ...'
    kubectl create -f bbr.yaml
    kubectl expose deployment bbr --type=LoadBalancer --name=bbr-tcp --port=$SP --external-ip $IP --protocol="TCP"
else
    kubectl expose deployment caddy --type=LoadBalancer --name=caddy-tcp --port=$SP --external-ip $IP --protocol="TCP"
fi
kubectl expose deployment caddy --type=LoadBalancer --name=caddy-udp --port=$SP --external-ip $IP --protocol="UDP"

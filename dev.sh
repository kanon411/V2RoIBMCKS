#!/bin/bash

# 定义参数检查
paras=$@
function checkPara(){
    local p=$1
    for i in $paras; do if [[ $i == $p ]]; then return; fi; done
    false
}

# 设定区域
REGION=ng # Dallas, USA
checkPara 'au' && REGION=au-syd # Sydney, Australia
checkPara 'uk' && REGION=eu-gb # London, England
checkPara 'de' && REGION=eu-de # Frankfurt, Germany

# 安装 IBM Cloud CLI
echo -e '\nDownload IBM Cloud CLI ...'
curl -Lo IBM_Cloud_CLI_amd64.tar.gz https://clis.cloud.ibm.com/download/bluemix-cli/latest/linux64
echo -e '\nInstall IBM Cloud CLI ...'
tar -zxf IBM_Cloud_CLI_amd64.tar.gz
cd Bluemix_CLI
sudo ./install_bluemix_cli
ibmcloud config --usage-stats-collect false

#登录到 IBM Cloud CLI
echo -e -n '\n请输入用户名：'
read USERNAME
while [ -z $USERNAME ];
do
    echo -n '未输入用户名，请重新输入：'
    read USERNAME
done
echo -e -n '\n请输入密码：'
read -s PASSWD
while [ -z $PASSWD ];
do
    echo -e -n '\n未输入密码，请重新输入：'
    read -s PASSWD
done
echo -e '\n'
while ibmcloud login -a https://api.${REGION}.bluemix.net -u $USERNAME -p $PASSWD 2>&1 | grep -q "Credentials were rejected"
do
    echo -e '\n用户名或密码错误，请核对后重新输入！'
    echo -e -n '\n请输入用户名：'
    read USERNAME
    while [ -z $USERNAME ];
    do
        echo -n '未输入用户名，请重新输入：'
        read USERNAME
    done
    echo -e -n '\n请输入密码：'
    read -s PASSWD
    while [ -z $PASSWD ];
    do
        echo -e -n '\n未输入密码，请重新输入：'
        read -s PASSWD
    done
    echo -e '\n'
done
echo 'OK'
echo
(echo 1; echo 1) | ibmcloud target --cf  #Target Cloud Foundry org/space.

# 安装 IBM Cloud CLI 插件
echo -e '\nInstall IBM Cloud CLI plugin ...'
ibmcloud plugin install container-service -r Bluemix
ibmcloud plugin install container-registry -r Bluemix
ibmcloud ks init

# 安装 kubectl
echo -e '\nDownload kubectl ...'
KUBEVER=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
curl -Lo kubectl https://storage.googleapis.com/kubernetes-release/release/${KUBEVER}/bin/linux/amd64/kubectl
echo -e '\nInstall kubectl ...'
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
echo

# 显示 kubectl 版本，提示配置运行环境 
KUBE_ENV=$(ibmcloud ks cluster-config $(ibmcloud ks clusters -s | grep 'normal' | awk '{print $1}') --export -s)
$KUBE_ENV
echo -e '\nKubectl version:'
kubectl version  --short
echo -e '\nTo Configurate IBM Cloud CLI to run kubectl, copy and run:'
echo
echo $KUBE_ENV
echo

#!/bin/bash

#判断系统
if [ ! -e '/etc/redhat-release' ]; then
echo "仅支持centos7"
exit
fi
if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
echo "仅支持centos7"
exit
fi



#更新内核
update_kernel(){

    yum -y install epel-release curl
    sed -i "0,/enabled=0/s//enabled=1/" /etc/yum.repos.d/epel.repo
    yum remove -y kernel-devel
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
    rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm
    yum --disablerepo="*" --enablerepo="elrepo-kernel" list available
    yum -y --enablerepo=elrepo-kernel install kernel-ml
    sed -i "s/GRUB_DEFAULT=saved/GRUB_DEFAULT=0/" /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg
    wget https://elrepo.org/linux/kernel/el7/x86_64/RPMS/kernel-ml-devel-4.19.1-1.el7.elrepo.x86_64.rpm
    rpm -ivh kernel-ml-devel-4.19.1-1.el7.elrepo.x86_64.rpm
    yum -y --enablerepo=elrepo-kernel install kernel-ml-devel
    read -p "需要重启VPS，再次执行脚本选择安装wireguard，是否现在重启 ? [Y/n] :" yn
	[ -z "${yn}" ] && yn="y"
	if [[ $yn == [Yy] ]]; then
		echo -e "VPS 重启中..."
		reboot
	fi
}

#生成随机端口
rand(){
    min=$1
    max=$(($2-$min+1))
    num=$(cat /dev/urandom | head -n 10 | cksum | awk -F ' ' '{print $1}')
    echo $(($num%$max+$min))  
}

wireguard_update(){
    yum update -y wireguard-dkms wireguard-tools
    echo "更新完成"
}

wireguard_remove(){
    wg-quick down wg0
    yum remove -y wireguard-dkms wireguard-tools
    rm -rf /etc/wireguard/
    echo "卸载完成"
}

config_client(){
cat > /etc/wireguard/client.conf <<-EOF
[Interface]
PrivateKey = $c1
Address = 10.77.77.2/32
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $s2
Endpoint = $serverip:$port
AllowedIPs = 0.0.0.0/0, ::0/0
PersistentKeepalive = 25
EOF

}

#centos7安装wireguard
wireguard_install(){
    curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
    yum install -y dkms gcc-c++ gcc-gfortran glibc-headers glibc-devel libquadmath-devel libtool systemtap systemtap-devel
    yum -y install wireguard-dkms wireguard-tools
    yum -y install qrencode
    mkdir /etc/wireguard
    mkdir /etc/wireguard/client
    cd /etc/wireguard
    wg genkey | tee sprivatekey | wg pubkey > spublickey
    wg genkey | tee cprivatekey | wg pubkey > cpublickey
    s1=$(cat sprivatekey)
    s2=$(cat spublickey)
    c1=$(cat cprivatekey)
    c2=$(cat cpublickey)
    serverip=$(curl ipv4.icanhazip.com)
    #port=$(rand 10000 60000)
    #服务端口(DUP协议)
    port=1198
    eth=$(ls /sys/class/net | grep e | head -1)
    #端口转发规则
    eth0ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "1"p)
    Dcp_PostUp="iptables -t nat -A PREROUTING -d ${eth0ip} -p tcp --dport 31400:31409 -j DNAT --to-destination 10.77.77.2;iptables -t nat -A POSTROUTING -d 10.77.77.2  -p tcp --dport 31400:31409 -j SNAT --to ${eth0ip}"
    Dcp_PostDown="iptables -t nat -D PREROUTING -d ${eth0ip} -p tcp --dport 31400:31409 -j DNAT --to-destination 10.77.77.2;iptables -t nat -D POSTROUTING -d 10.77.77.2  -p tcp --dport 31400:31409 -j SNAT --to ${eth0ip}"
    chmod 777 -R /etc/wireguard
    systemctl stop firewalld
    systemctl disable firewalld
    yum install -y iptables-services 
    systemctl enable iptables 
    systemctl start iptables 
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    service iptables save
    service iptables restart
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p
cat > /etc/wireguard/wg0.conf <<-EOF
[Interface]
PrivateKey = $s1
Address = 10.77.0.1/16 
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -I FORWARD -s 10.77.77.1/24 -d 10.77.77.1/24 -j DROP; iptables -t nat -A POSTROUTING -o $eth -j MASQUERADE; $Dcp_PostUp;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -D FORWARD -s 10.77.77.1/24 -d 10.77.77.1/24 -j DROP; iptables -t nat -D POSTROUTING -o $eth -j MASQUERADE; $Dcp_PostDown;
ListenPort = $port
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $c2
AllowedIPs = 10.77.77.2/32
EOF

    config_client
    wg-quick up wg0
    systemctl enable wg-quick@wg0
    content=$(cat /etc/wireguard/client.conf)
    echo "电脑端请下载client.conf，手机端可直接使用软件扫码"
    echo "${content}" | qrencode -o - -t UTF8
}
add_user(){
    echo -e "\033[37;41m给新用户起个名字，不能和已有用户重复\033[0m"
    read -p "请输入用户名：" newname
    cd /etc/wireguard/client
    cp /etc/wireguard/client.conf $newname.conf
    wg genkey | tee temprikey | wg pubkey > tempubkey
    ipnum=$(grep Allowed /etc/wireguard/wg0.conf | tail -1 | awk -F '[ ./]' '{print $6}')
    newnum=$((10#${ipnum}+1))
    sed -i 's%^PrivateKey.*$%'"PrivateKey = $(cat temprikey)"'%' $newname.conf
    sed -i 's%^Address.*$%'"Address = 10.77.77.$newnum\/32"'%' $newname.conf

cat >> /etc/wireguard/wg0.conf <<-EOF
[Peer]
PublicKey = $(cat tempubkey)
AllowedIPs = 10.77.77.$newnum/32
EOF
    wg set wg0 peer $(cat tempubkey) allowed-ips 10.77.77.$newnum/32
    echo -e "\033[37;41m添加完成，文件：/etc/wireguard/client/$newname.conf\033[0m"
    content=$(cat /etc/wireguard/client/$newname.conf)
    echo "电脑端请下载$newname.conf，手机端可直接使用软件扫码"
    echo "${content}" | qrencode -o - -t UTF8
    rm -f temprikey tempubkey
}
#开始菜单
start_menu(){
    clear
    echo "========================="
    echo " 介绍：wireguard一键脚本"
    echo " 系统：适用于CentOS7"
    echo " 作者：天道"
    echo " 微信：51529502"
    echo "========================="
    echo "1. 升级系统内核"
    echo "2. 安装wireguard"
    echo "3. 升级wireguard"
    echo "4. 卸载wireguard"
    echo "5. 显示客户端二维码"
    echo "6. 增加用户"
    echo "0. 退出脚本"
    echo
    read -p "请输入数字:" num
    case "$num" in
    	1)
	update_kernel
	;;
	2)
	wireguard_install
	;;
	3)
	wireguard_update
	;;
	4)
	wireguard_remove
	;;
	5)
	content=$(cat /etc/wireguard/client.conf)
    	echo "${content}" | qrencode -o - -t UTF8
	;;
	6)
	add_user
	;;
	0)
	exit 1
	;;
	*)
	clear
	echo "请输入正确数字"
	sleep 5s
	start_menu
	;;
    esac
}

start_menu




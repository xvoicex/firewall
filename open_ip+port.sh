time=$(date +%F@%T)
file=/root/firewall/ip
lines=$(cat $file |wc -l)
echo -e 一共 $lines 个IP
echo 端口： $1

if [ ! $1 ];then
	echo -e 没有传入端口
	exit 0
fi

for (( line=1 ; line<=$lines ; line= line + 1 ))
do
                b=$(head -n $line $file | tail -n 1)
                if [ ! $b ];then
                        echo -e 请检查 $file
                        break
                else
			echo ""
                        echo -e 正在放通IP $b 到端口 $0 
                        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address='$b' port protocol="tcp" port='$1' accept'
			firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address='$b' port protocol="udp" port='$1' accept'
                fi
done
firewall-cmd --reload
firewall-cmd --list-rich-rules

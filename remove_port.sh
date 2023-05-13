time=$(date +%F@%T)
file=/root/firewall/port
lines=$(cat $file |wc -l)
echo -e 一共 $lines 个IP


for (( line=1 ; line<=$lines ; line= line + 1 ))
do
                b=$(head -n $line $file | tail -n 1)
                if [ ! $b ];then
                        echo -e 请检查 $file
                        break
                else
                        echo ""
                        echo  ###################  正在移除端口：$b ###################
                        firewall-cmd --zone=public --remove-port=$b"/tcp" --permanent
                        firewall-cmd --zone=public --remove-port=$b"/udp" --permanent
                fi
done
firewall-cmd --reload
firewall-cmd --list-port

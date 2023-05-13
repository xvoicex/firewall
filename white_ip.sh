time=$(date +%F@%T)
file=/root/firewall/ip
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
                        echo  -e  ###################  正在添加白名单IP：$b ###################
                        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address='$b' accept'
                fi
done
firewall-cmd --reload
firewall-cmd --list-rich-rules

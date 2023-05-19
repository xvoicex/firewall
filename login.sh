#w |grep root |awk '{printf $3 "\n"}' |grep -v "[a-zA-Z]\|192.168."
time=$(date +%F@%T)
lines=$(w |grep root |awk '{printf $3 "\n"}' |grep -v "[a-zA-Z]\|192.168."|wc -l)
echo -e $(w |grep root |awk '{printf $3 "\n"}' |grep -v "[a-zA-Z]\|192.168.")
for (( line=1 ; line<=$lines ; line= line + 1 ))
do
                b=$(w |grep root |awk '{printf $3 "\n"}' |grep -v "[a-zA-Z]\|192.168."|head -n $line | tail -n 1)
                if [[ ! $b || $line > $lines ]];then
			echo 退出
                        break
                else
                        echo  -e  正在添加白名单IP：$b 
                        firewall-cmd --add-rich-rule='rule family="ipv4" source address='$b' accept'
                fi
done
#firewall-cmd --reload
#firewall-cmd --list-rich-rules |grep accept

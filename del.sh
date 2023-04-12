time=$(date +%F@%T)
file=/root/firewall/del
lines=$(cat $file |wc -l)
echo -e 一共 $lines 条规则

for (( line=1 ; line<=$lines ; line= line + 1 ))
do
                b=$(head -n $line $file | tail -n 1)
                echo -e ###################  正在删除第 $line 条规则  ###################
               	firewall-cmd --permanent --remove-rich-rule=" $b "
#		echo $b
done
firewall-cmd --reload
firewall-cmd --list-rich-rules

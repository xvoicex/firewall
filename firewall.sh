#/bin/bash
time=$(date +%F@%T)
echo -e 删除30天前的日志...
find /root/firewall/log/ -mtime +30 -name '*.log' | xargs rm -f
echo -e 保存lastb日志...
lastb > /root/firewall/log/lastb-$time.log
file=/root/firewall/log/$time.log
grep "Connection closed" /var/log/secure | awk '{printf $9 "\n"}' |awk '{++S[$NF]} END{for (a in S)print a,S[a]}' |awk '{if($2>10)print $0}' |sort -nrk2 |awk '{printf $1 "\n"}'  >  $file
lines=$(cat $file |wc -l)
echo -e 一共 $lines 个IP
for (( line=1 ; line<=$lines ; line= line + 1 ))
do
                b=$(head -n $line $file | tail -n 1)
                if [ ! $b ];then
                        echo -e 请检查 $file
                        break
                else
                        echo -e 正在禁用：$b
                        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address='$b' reject'
                fi
done
echo -e 发送邮件...
mail -a /root/firewall/log/lastb-$time.log -s "N1_firewall" vx@vxoice.onmicrosoft.com < $file
#echo -e 清空btmp文件...
#echo > /var/log/btmp
echo -e 更新防火墙规则...
firewall-cmd --reload
c=$(firewall-cmd --list-rich-rules|grep reject |grep ipv4 |awk '{printf $4 "\n"}' |sed 's/address=//g;s/"//g' | wc -l)
echo -e 共$c条,禁用IP列表：
firewall-cmd --list-rich-rules |grep reject  > /root/firewall/README.md
cat README.md
cd /root/firewall && bash git_localhost.sh README.md $time 

time=$(date +%F@%T)
#file=/root/firewall/ip
#lines=$(cat $file |wc -l)
echo -e 临时开通IP $1,不输入IP则清除临时策略

                if [ ! $1 ];then
                        echo -e 清除临时策略
                        firewall-cmd --reload
                else
                        echo ""
                        echo  -e  正在添加临时IP：$1 
                        firewall-cmd  --add-rich-rule='rule family="ipv4" source address='$1' accept'
                fi

#firewall-cmd --reload
firewall-cmd --list-rich-rules |grep accept

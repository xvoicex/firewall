#/bin/bash
frpc=/tmp/frpc/frpc
frp_path=/tmp/frpc/
tmp_path=/tmp/
frpid=$(pidof frpc)
#ver=$($frpc -v)
arch=mipsle
#ver=1
version=$(curl -s  https://api.github.com/repos/fatedier/frp/releases/latest |grep tag_name |sed 's/[tag_name " : , v]/ /g' |sed 's/ //g')
frpc_tmp='/tmp/frp_'$version'_linux_'$arch''
gz_tmp='/tmp/frp_'$version'_linux_'$arch'.tar.gz'
sha256_file='/tmp/frp_'$version'_sha256.txt'
#wget https://github.com/fatedier/frp/releases/download/v'$version'/frp_sha256_checksums.txt
#wget 'https://github.com/fatedier/frp/releases/download/v'$version'/frp_'$version'_linux_mipsle.tar.gz'



checkfrpc(){
if [[ -z $frpid ]]; then
		echo -e "\033[33mfrpc进程不存在，启动frpc\033[0m"
		/tmp/frpc/frpc -c /root/frpc.toml 2>&1 &
else
		echo -e "\033[32mfrpc进程id:\033[0m" "\033[33m $frpid \033[0m"
fi
#kill -9 $frpid
}

checksha256(){
if [ -f $gz_tmp ];then
		echo $gz_tmp 文件存在
else
		echo -e "\033[31m 文件下载失败，退出 \033[0m"
		exit 1
fi

sha256=$(echo $(cat $sha256_file |grep $arch|awk '{printf $1}'))
check_sha256=$(echo $(/usr/bin/sha256sum $gz_tmp)|awk '{printf $1}')
		echo -e sha256检测通过 "\033[32m $check_sha256 \033[0m"
		echo $sha256
		echo $check_sha256
		tar_frp && checkfrpc
}


###检查文件
checkfile(){
if [ -f $gz_tmp ] && [ -f $md5_file ];then
		echo "tmp文件存在"
				if [ -f $frpc ];then
						echo frpc文件存在,启动frpc
						checkfrpc
				else
						echo frps文件不存在，解压文件并启动服务
						tar_frp && checkfrpc
				fi
else
		echo "文件不存在"
		rm -f '/tmp/frp_'$version'_linux_'$arch'.tar.gz' && rm -f '/tmp/frp_'$version'_sha256.txt'
		echo "下载sha256文件---------------------"
		wget 'https://github.com/fatedier/frp/releases/download/v'$version'/frp_sha256_checksums.txt' -O $sha256_file
		echo "下载frp文件---------------------"
		wget 'https://github.com/fatedier/frp/releases/download/v'$version'/frp_'$version'_linux_'$arch'.tar.gz' -O $gz_tmp
		checksha256
		tar_frp && checkfrpc
fi
}

tar_frp(){

tar -xz -C /tmp/ -f $gz_tmp
mv $frpc_tmp /tmp/frpc

}


version(){
if [ "$ver" != "$version" ] ; then
		echo 版本$ver不是最新,最新是$version
		if [[ -z $frpid ]]; then
				echo 移除旧版frp文件
				rm -rf /tmp/frpc && rm -f '/tmp/frp_'$ver'_linux_'$arch'.tar.gz' && rm -f '/tmp/frp_'$ver'_sha256.txt'
				checkfile
		else
				echo -e frpc进程id："\033[31m $frpid \033[0m"，关闭进程移除旧版frp文件
				kill -9 $frpid
				rm -rf /tmp/frpc && rm -f '/tmp/frp_'$ver'_linux_'$arch'.tar.gz' && rm -f '/tmp/frp_'$ver'_sha256.txt'
				checkfile
		fi
else
		echo -e "\033[32m版本\033[0m""\033[31m$ver\033[0m""\033[32m与服务器版本""\033[31m$version\033[0m""\033[32m一致\033[0m"
		checkfrpc
fi
}




if [ -f $frpc ]; then 
		ver=$($frpc -v)
		version 2>&1
else
		echo -e "\033[33m frp文件不存在\033[0m"  ##黄色文字
		checkfile
fi


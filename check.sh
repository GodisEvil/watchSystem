#!/bin/bash

EMAIL_ADDRESS=('xxx@gmail.com' 'xxx@gmail.com')
#LOCAL_SERVER_NAME='1.2.3.4'

function sendEmail()	{
	if [ $# -ne 3 ]; then
		echo 'Send nothing is not allowed' >&2
		return 1
	fi
	local errType=$1
	#local subject="${LOCAL_SERVER_NAME}: $2"
	local subject="$2"
	## 把制表符替换成空格；换行符替换成<br>
	local msg=`echo "${3}" | tr '\t ' ' ' | sed ':a;N;$!ba;s/\n/<br>/g'`
	if [ $DEBUG ]; then
		echo "${subject}"
		echo "${msg}"
	else
		for email in ${EMAIL_ADDRESS[@]}; do
			#echo curl --connect-timeout 10 -H 'Content-Type: application/json' -d "{\"to\":\"${email}\", \"subject\":\"${subject}\",\"msg\":\"${msg}\"}" "http://xxxx/email/send" >>debug.log
			curl --connect-timeout 10 -H 'Content-Type: application/json' -d "{\"to\":\"${email}\", \"subject\":\"${subject}\",\"msg\":\"${msg}\"}" "http://xxxx/email/send"
			## 可能对方的服务器挂掉了，那么先记录到本地，直接退出
			if [ $? -ne 0 ]; then
				date '+%Y-%m-%d %H:%M:%S' >> email_unsend.txt
				echo "${subject}" >> email_unsend.txt
				echo "${msg}" >> email_unsend.txt
				exit 1
			else
				touch "$errType"
			fi
		done
	fi
}


## 检查某个类型十分钟内是否已经发送过邮件，发送过的话就直接退出
function hasSendEmail()	{
	if [ $# -ne 1 ]; then
		echo 'need type' >&2
		return 1
	fi
	local errType=$1
	if [ ! -f "${errType}" ]; then
		return 0
	fi
	local mtime=`stat -c %Y ${errType}`
	local now=`date +%s`
	if [ `echo "${now} - ${mtime} < 600" | bc` == '1' ]; then
		echo "send ${errType} in 10 minutes, will not check it this time"
		exit 1
	fi
}


## idle percent，运行 mpstat -P ALL ，检查 idle% 低于 CPU_LOW
# 或者 iowait 高于 CPU_IOWAIT_MAX 则报警
CPU_LOW=10
CPU_INTERV=2
CPU_IOWAIT_MAX=10

## 检查 iowait 和 idle
function checkCPU() {
	local errType='cpu'
	hasSendEmail "${errType}"
	## 前3行不是数值
	local status=`mpstat -P ALL`
	echo "${status}" | tail -n +4 | while read line; do
		local iowait=`echo $line | awk '{print $7}'`
		## 如果 iowait 
		if [ `echo "${iowait} > ${CPU_IOWAIT_MAX}" | bc` == '1' ]; then
			sendEmail "${errType}" 'cpu iowait too high' "${status}"
			return 1
		fi
		local idle=`echo "$line" | awk '{print $NF}'`
		if [ `echo "${idle} < ${CPU_LOW}" | bc` == '1' ]; then
			sendEmail "${errType}" 'cpu occupy too high' "${status}"
			return 1
		fi
	done
}


## MB，运行 free -m，检查 free + buff/cache 低于 MEM_LOW，
# 或者占 total 的比例低于 MEM_LOW_PERCENT，或者 swap 大小超过 MEM_SWAP_MAX 则报警
MEM_LOW=100
#MEM_LOW_PERCENT=10
MEM_INTERV=2
#MEM_SWAP_MAX=1024

function checkMem()	{
	local errType='mem'
	hasSendEmail "${errType}"
	## 第二行是内存数据，第三行是 swap
	local status=`free -m`
	local totalMem=`echo "${status}" | sed -n '2p' | awk '{print $2}'`
	local freeMem=`echo "${status}" | sed -n '2p' | awk '{print $4+$6}'`
	if [ `echo "${freeMem} < ${MEM_LOW}" | bc` == '1' ]; then
		sendEmail "${errType}" 'mem free too less' "${status}"
		return 1
	fi
#	local swapInfo=`echo ${status} | sed -n '4p'`
}

## KB ，运行 df -h，检查 /dev/xxx 格式的 filesystem 剩余大小，低于 ROM_LOW
# 或者 USE% 高于 ROM_USE_PERCENT 则报警
# 或者某个磁盘的 inode 使用率超过了 ROM_INODE_MAX 报警
ROM_LOW=1048576
#ROM_USE_PERCENT=90
ROM_INTERV=10
ROM_INODE_MAX=80

function checkROM()	{
	local errType='rom'
	hasSendEmail "${errType}"
	## 只检查 /dev/ 开头的行
	local sizeStatus=`df`
	echo "${sizeStatus}" | grep '^/dev/' | while read line; do
		local avaSize=`echo $line | awk '{print $4}'`
		if [ `echo "${avaSize} < ${ROM_LOW}" | bc` == '1' ]; then
			sendEmail "${errType}" 'rom avaiable too less' "${sizeStatus}"
			return 1
		fi
	done
	local inodeStatus=`df -i`
	echo "${inodeStatus}" | grep '^/dev/' | while read line; do
		local inodeUsed=`echo ${line} | awk '{print $5}'`
		inodeUsed=${inodeUsed::0-1}
		if [ `echo "${inodeUsed} > ${ROM_INODE_MAX}" | bc` == '1' ]; then
			sendEmail "${errType}" 'rom inode left too little' "${inodeStatus}"
			return 1
		fi
	done
}


## kb/s，把 /proc/net/dev 的输出整理下，每隔一秒读取一次，通过增量可以获得即时网速，
# 注意网速是 bit/s，而读取的结果是 bytes, 1byte = 8bit
# 去掉 lo 的数据即可
# 出口带宽高于 BANDWIDTH 或者占 BANDWIDTH_MAX 的比例超过了 BANDWIDTH_PERCENT 则报警
## 5M 带宽就是 5 * 1024 * 1024 = 5242880 bytes/s，4M时提醒 
BANDWIDTH=4194304
#BANDWIDTH_MAX=102400
#BANDWIDTH_PERCENT=90
BANDWIDTH_INTERV=5
ETH_LIST=('eth0' 'eth1')

function checkNet()	{
	local errType='net'
	hasSendEmail "${errType}"
	local status=`cat /proc/net/dev; sleep 1; cat /proc/net/dev`
	for i in ${ETH_LIST[@]}; do
		local bandwidth=`echo "${status}" | grep ${i} | awk 'BEGIN {t1=0; t2=0} {if (NR==1) t1=$2; else if (NR==2) t2=$2;} END {print t2-t1}'`
		if [ `echo "${bandwidth} > ${BANDWIDTH}" | bc` == '1' ]; then
			sendEmail "${errType}" 'net bandwidth occupy too much' "${status}"
			return 1
		fi
	done
}


## 检查 process 是否存在，不存在则报警
PROCESS_LIST=('httpd' 'mysqld')
PROCESS_INTERV=2

function checkProcess()	{
	local errType='process'
	hasSendEmail "${errType}"
	for i in ${PROCESS_LIST[@]}; do
		pidof ${i} >/dev/null
		if [ $? -ne 0 ]; then
			sendEmail "${errType}" "process ${i} is not running" "process ${i} is not running"
			return 1
		fi
	done
}


## 使用 socket 连接端口，无法完成三次握手则报警
PORT_LIST=(80 8080)
PORT_INTERV=1

function checkPort()	{
	local errType='port'
	hasSendEmail "${errType}"
	for i in ${PORT_LIST[@]}; do
		curl --connect-timeout 1 "http://localhost:${i}" >/dev/null 2>&1
		if [ $? -ne 0 ]; then
			sendEmail "${errType}" "port ${i} cannot connected with tcp" "Port ${i} connect failed"
			return 1
		fi
	done
}


## ping host，如果返回错误则报警
PING_LIST=('20.6.05.4' '19.2.8.10' '4.8.16.7' '4.8.10.4' '47.8.16.1' '5.9.19.15')
PING_INTERV=1

function checkHost()	{
	local errType='host'
	hasSendEmail "${errType}"
	for i in ${PING_LIST[@]}; do
		ping -c 1 -W 3 "${i}" >/dev/null
		if [ $? -ne 0 ]; then
			sendEmail "${errType}" "host ${i} ping failed" "Host ${i} ping failed"
			return 1
		fi
	done
}


if [ $# -ne 1 ]; then 
	echo 'Usage: check.sh cpu|mem|rom|net|process|port|host|all'
else
	cd `dirname $0`
	## 用 crontab 运行的时候，PATH=/usr/bin:/bin，而脚本中部分命令比如 pidof 可能在 /usr/sbin 或者 /sbin 目录下
	export PATH=/usr/sbin:/sbin:$PATH
	case ${1} in
		'cpu')	checkCPU
		;;
		'mem')	checkMem
		;;
		'rom')	checkROM
		;;
		'net')	checkNet
		;;
		'process')	checkProcess
		;;
		'port')	checkPort
		;;
		'host')	checkHost
		;;
		'all')	checkCPU; checkMem; checkROM; checkNet; checkProcess; checkPort; checkHost
	esac
fi



#!/bin/bash

EMAIL_ADDRESS=('xxx@gmail.com' 'xxx@gmail.com')

## 最多连续检测到这么多次错误就要发报警邮件，次数记录在 ERR_FLAG 文件里
ERR_MAX_TIMES=5
ERR_FLAG='errCnt'

## 判断是否要发送邮件，需要的话就返回0，否则返回1
## 先判断标记文件的时间是否2分钟内，如果不是则更新计数为1
## 如果是的，判断文件内数字加上本次是否超过 ERR_MAX_TIMES ，小于则返回 1； 否则返回 0
function isNeedEmail()	{
	if [ ! -f "${ERR_FLAG}" ]; then
		echo 1 > ${ERR_FLAG}
		return 1
	fi
	local mtime=`stat -c %Y ${ERR_FLAG}`
	local now=`date +%s`
	if [ `echo "${now} - ${mtime} < 120" | bc` == '1' ]; then
		local errTimes=`cat ${ERR_FLAG}`
		let "errTimes+=1"
		echo ${errTimes} > ${ERR_FLAG}
		if [ `echo "$errTimes < ${ERR_MAX_TIMES}" | bc` == '1' ]; then
			return 1
		else
			return 0
		fi
	else
		echo 1 > ${ERR_FLAG}
		return 1
	fi
}


## 检查十分钟内是否已经发送过邮件，发送过的话就直接退出
function hasSendEmail()	{
#	if [ $# -ne 1 ]; then
#		echo 'need type' >&2
#		return 1
#	fi
#	local errType=$1
	local errType="${ERR_FLAG}"
	if [ ! -f "${errType}" ]; then
		return 0
	fi
	local mtime=`stat -c %Y ${errType}`
	local now=`date +%s`
	if [ `echo "${now} - ${mtime} < 600" | bc` == '1' ]; then
		## 时间在10分钟之内，检查次数是否足以发送邮件；是的话则直接退出
		local errTimes=`cat "${errType}"`
		if [ `echo "${errTimes} >= ${ERR_MAX_TIMES}" | bc` == '1' ]; then
			echo "send ${errType} in 10 minutes, will not check it this time"
			exit 0
		else
			return 0
		fi
	fi
}


## 每次警告时记下来，连续5分钟有警告才发出邮件
function sendEmail()	{
	if [ $# -ne 3 ]; then
		echo 'Send nothing is not allowed' >&2
		return 1
	fi
	local errType=$1
	## 把邮件内容记录到相应错误类型
	echo "${2}" > "$errType"
	echo "${3}" >> "$errType"
	
	local subject="$2"
	## 把制表符替换成空格；换行符替换成<br>
	local msg=`echo "${3}" | tr '\t ' ' ' | sed ':a;N;$!ba;s/\n/<br>/g'`
	isNeedEmail
	## 不需要发邮件的话就直接返回
	if [ $? -ne 0 ]; then
		return 0
	fi
	if [ $DEBUG ]; then
		echo "${subject}"
		echo "${msg}"
	else
		for email in ${EMAIL_ADDRESS[@]}; do
			#echo curl --connect-timeout 10 -H 'Content-Type: application/json' -d "{\"to\":\"${email}\", \"subject\":\"${subject}\",\"msg\":\"${msg}\"}" "http://www.xxx.com/email/send" >>debug.log
			curl --connect-timeout 10 -H 'Content-Type: application/json' -d "{\"to\":\"${email}\", \"subject\":\"${subject}\",\"msg\":\"${msg}\"}" "http://www.xxx.com/email/send"
			## 可能对方的服务器挂掉了，那么先记录到本地，直接退出
			if [ $? -ne 0 ]; then
				date '+%Y-%m-%d %H:%M:%S' >> email_unsend.txt
				echo "${subject}" >> email_unsend.txt
				echo "${msg}" >> email_unsend.txt
				echo '' >> email_unsend.txt
				exit 1
			fi
		done
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
			sendEmail "${errType}" "cpu iowait is ${iowait}%" "${status}"
			return 1
		fi
		local idle=`echo "$line" | awk '{print $NF}'`
		if [ `echo "${idle} < ${CPU_LOW}" | bc` == '1' ]; then
			date '+%Y-%m-%d %H:%M:%S' >> ps.log
			ps auxf >> ps.log
			echo '' >> ps.log
			sendEmail "${errType}" "cpu idle is ${idle}" "${status}"
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
		date '+%Y-%m-%d %H:%M:%S' >> ps.log
		ps auxf >> ps.log
		echo '' >> ps.log
		sendEmail "${errType}" "mem free ${freeMem}" "${status}"
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
			sendEmail "${errType}" "rom avaiable is ${avaSize}" "${sizeStatus}"
			return 1
		fi
	done
	local inodeStatus=`df -i`
	echo "${inodeStatus}" | grep '^/dev/' | while read line; do
		local inodeUsed=`echo ${line} | awk '{print $5}'`
		inodeUsed=${inodeUsed%\%}
		if [ `echo "${inodeUsed} > ${ROM_INODE_MAX}" | bc` == '1' ]; then
			sendEmail "${errType}" "rom inode used ${inodeUsed}%" "${inodeStatus}"
			return 1
		fi
	done
}


## kb/s，把 /proc/net/dev 的输出整理下，每隔一秒读取一次，通过增量可以获得即时网速，
# 注意网速是 bit/s，而读取的结果是 bytes, 1byte = 8bit
# 去掉 lo 的数据即可
# 出口带宽高于 BANDWIDTH 或者占 BANDWIDTH_MAX 的比例超过了 BANDWIDTH_PERCENT 则报警
## 5M 带宽就是 5 * 1024 * 1024 / 8 = 655360 bytes/s，4M时提醒 
BANDWIDTH=524288
#BANDWIDTH_MAX=102400
#BANDWIDTH_PERCENT=90
BANDWIDTH_INTERV=5
ETH_LIST=('eth0' 'eth1')

function checkNet()	{
	local errType='net'
	hasSendEmail "${errType}"
	local status=`cat /proc/net/dev; sleep 1; cat /proc/net/dev`
	for i in ${ETH_LIST[@]}; do
		local outBandwidth=`echo "${status}" | grep ${i} | awk 'BEGIN {t1=0; t2=0} {if (NR==1) t1=$10; else if (NR==2) t2=$10;} END {print t2-t1}'`
		if [ `echo "${outBandwidth} > ${BANDWIDTH}" | bc` == '1' ]; then
			if which iftop; then
				date '+%Y-%m-%d %H:%M:%S' >> iftop.log
				iftop -N -b -B -t -s 1 -i "${i}" >> iftop.log
				echo '' >> iftop.log
			fi
			sendEmail "${errType}" "net bandwidth occupy ${outBandwidth} bytes/s" "${status}"
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
PING_LIST=('1.2.5.4' '1.2.8.6' '4.8.1.7' '4.8.1.6' '4.8.6.6' '5.9.6.1')
PING_INTERV=1

function checkHost()	{
	local errType='host'
	hasSendEmail "${errType}"
	for i in ${PING_LIST[@]}; do
		## ping 2 times
		ping -c 2 -W 3 "${i}" >/dev/null
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



#!/bin/bash -e
#
# Run rule-install-rate on a pre-generated set of rules
#
# Author: Marcelo Ricardo Leitner, 2018
# GPLv3
#

iface=
rules=100000
skip=""   # skip_hw / skip_sw   (place holder, neither are supported :)
batchfile=tc-rules.batch

usage()
{
	echo "Usage: $0 -i <interface> [-n count] [-f skip_flag]"
	echo "where count must be 0 < count < 100000,"
	echo "      if specified, skip_flag = <skip_sw|skip_hw>"
	echo "      although neither flags are supported by the perf probes yet."
	exit 1
}

parse_cmdline()
{
	while [ $# -ge 1 ]; do
		opt="$1"
		shift
		case "$opt" in
		-i)
			iface="$1"
			shift
			if [ -z "$iface" ]; then
				echo "Invalid interface '$iface'."
				usage
			fi
			if [ ! -e "/sys/class/net/$iface" ]; then
				echo "Interface '$iface' not found."
			fi
			;;
		-n)
			rules="$1"
			shift
			if [ "$rules" -le 0 -o "$rules" -gt 100000 ]; then
				echo "Invalid count of rules '$rules'."
				usage
			fi
			;;
		-f)
			skip="$1"
			shift
			if [ "$skip" != skip_hw -a "$skip" != skip_sw ]; then
				echo "Invalid skip flag '$skip'."
				usage
			fi
			;;
		-h)
			usage
			;;
		*)
			echo "Invalid argument '$opt'."
			usage
		esac
	done

	if [ -z "$iface" ]; then
		echo "You must specify one interface."
		usage
	fi
}


check_rpm()
{
	ret=0
	for i in "$@"; do
		if ! rpm -q $i >& /dev/null; then
			echo "Please install $i"
			ret=1
		fi
	done
	return $ret
}

check_perf()
{
	if ! type -Pp perf 2> /dev/null; then
		echo "Please install perf."
		exit 1
	fi

	if perf probe -L __kmalloc >& /dev/null; then
		return
	fi
	if perf probe -s /lib/modules/$(uname -r)/source/ -L __kmalloc; then
		return
	fi

	echo "Perf can't list code. You're missing debuginfos."
	exit 1
}

check_system()
{
	check_rpm gnuplot
	check_perf
}

#
# Load as much as possible
#
generate_batch()
{
	s=$(date +%s)
	echo "Generating $batchfile..."
	python3 > $batchfile <<EOF
for i in range($rules):
	a=i & 0xff
	b=(i & 0xff00) >> 8
	c=(i & 0xff0000) >> 16
	print("filter add dev $iface parent ffff: protocol ip prio 1 flower $skip \
	       src_mac ec:13:db:%02X:%02X:%02X dst_mac ec:14:c2:%02X:%02X:%02X \
	       src_ip 56.%d.%d.%d dst_ip 55.%d.%d.%d \
	       action drop" % (a, b, c, c, b, a, a, b, c, c, b, a))
EOF
	e=$(date +%s)
	echo "Generated $rules rules in $((e-s)) seconds."
}

get_multiple_batch() {
	size=$((rules/4))
	head -n $size $batchfile > cpu1.batch
	sed -n -e $((size+1)),$((size*2))p $batchfile > cpu2.batch
	sed -n -e $((size*2+1)),$((size*3))p $batchfile > cpu3.batch
	tail -n $size $batchfile > cpu4.batch
}

prep_batch()
{
	if [ ! -f $batchfile ]; then
		[ ! -e $batchfile ] || rm -f $batchfile
		generate_batch
	fi

	lines=$(wc -l $batchfile)
	lines=${lines/ *}
	if [ $lines != $rules ]; then
		generate_batch
	fi
}


cleanup()
{
	echo "Cleaning up ingress qdisc."
	#echo "  removing it..."
	#tc qdisc del dev $iface ingress || :
	#echo "  adding it back..."
	#tc qdisc add dev $iface ingress
	tc filter flush dev $iface
	echo "Done."
}

do_test()
{
	./rule-install-rate.py capture -- taskset -c 1 tc -b $batchfile
}

generate_report()
{
	./rule-install-rate.py parse
}

main()
{
	parse_cmdline "$@"
	check_system
	cleanup
	prep_batch
	get_multiple_batch
	#do_test
	#generate_report

	modprobe cls_flower

	./perf-probes.sh
	done=$(mktemp)
	touch $done
	perf record -e probe:* -o perf.data -aR -- inotifywait -e delete $done &
	
	perf_pid=$!
	pids=
	echo "Adding flows."
	echo 3 > /proc/sys/vm/drop_caches

	for cpu in {1,2,3,4}; do 
	    echo $cpu
	    tc -b cpu$cpu.batch &
	    pids="$pids $!"
	done
	wait $pids
	rm -f $done
	wait $perf_pid

	echo "Added flows."
	#./perf-plot.sh > /tmp/run.data #Script called in the test. 

: <<'END'

	./perf-probes.sh
	perf record -e probe:* -aR -- sleep 200&

	echo "Adding flows."
        echo 3 > /proc/sys/vm/drop_caches

        for cpu in {1,2,3,4}; do
            echo $cpu
            tc -b cpu$cpu.batch &
        done

	sleep 230
	echo "Added flows."
	./perf-plot.sh > /tmp/run.data
END
}

main "$@"

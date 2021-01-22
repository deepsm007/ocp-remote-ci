#!/bin/bash
# Load profile vars

if [[ ! -f profile.sh ]]; then
	echo "Profile.sh file missing"
fi

. profile.sh

set -o nounset
set -o pipefail
set -o errexit

# Default Ports
LIBVIRT_PORT=16509
API_PORT=6443
HTTP_PORT=80
HTTPS_PORT=443

# Debug and verify input
if [[ -z "${TOKEN:-}" ]]; then
	echo "[FATAL] \${token} must be set to the credentials of the port-forwarder service account."
	exit 1
elif [[ -z "${ENVIRONMENT:-}" ]]; then
	echo "[FATAL] \${environment} must be set to specify which bastion to interact with."
	exit 1
elif [[ -z "${CLUSTER_CAPACITY:-}" ]]; then
	echo "[FATAL] \${CLUSTER_CAPACITY} must be set to specify cluster capacity."
	exit 1
elif [[ -z "${CLUSTER_ID:-}" ]]; then
	echo "[FATAL] \${CLUSTER_ID} must be set to specify cluster."
	exit 1
fi

# Declaring and setting Bastion and Local ports
declare -A BASTION_PORTS
declare -A LOCAL_PORTS
BASTION_PORTS["LIBVIRT"]=$(($LIBVIRT_PORT + $CLUSTER_ID))
BASTION_PORTS["0,API"]=$(($API_PORT + $CLUSTER_ID))
BASTION_PORTS["0,HTTP"]=$(($HTTP_PORT + $CLUSTER_ID + 8000))
BASTION_PORTS["0,HTTPS"]=$(($HTTPS_PORT + $CLUSTER_ID + 8000))
PORTS="-R ${BASTION_PORTS["LIBVIRT"]}:127.0.0.1:$LIBVIRT_PORT \
       -R ${BASTION_PORTS["0,API"]}:127.0.0.1:$(($API_PORT + 80000)) \
	   -R ${BASTION_PORTS["0,HTTP"]}:127.0.0.1:$(($HTTP_PORT + 80000)) \
	   -R ${BASTION_PORTS["0,HTTPS"]}:127.0.0.1:$(($HTTPS_PORT + 80000))"
for i in $(seq 1 $CLUSTER_CAPACITY); do
        BASTION_PORTS["$i,API"]=$(($API_PORT + $CLUSTER_ID + 10000 * $i))
        BASTION_PORTS["$i,HTTP"]=$(($HTTP_PORT + $CLUSTER_ID + 10000 * $i))
        BASTION_PORTS["$i,HTTPS"]=$(($HTTPS_PORT + $CLUSTER_ID + 10000 * $i))
		LOCAL_PORTS["$i,API"]=$(($API_PORT + 10000 * $i))
		LOCAL_PORTS["$i,HTTP"]=$(($HTTP_PORT + 10000 * $i))
		LOCAL_PORTS["$i,HTTPS"]=$(($HTTPS_PORT + 10000 * $i))
		PORTS+=" -R ${BASTION_PORTS["$i,API"]}:127.0.0.1:${LOCAL_PORTS["$i,API"]}
				 -R ${BASTION_PORTS["$i,HTTP"]}:127.0.0.1:${LOCAL_PORTS["$i,HTTP"]}
				 -R ${BASTION_PORTS["$i,HTTPS"]}:127.0.0.1:${LOCAL_PORTS["$i,HTTPS"]}"
done

function OC() {	
	./oc --server https://api.ci.openshift.org --token "${TOKEN}" --namespace "${ENVIRONMENT}" "${@}"
}

function timestamp() {
	# With UTC format.  2020-11-04 06:19:24
	date -u  +"%Y-%m-%d %H:%M:%S"
}

function port-forward() {
	while true; do
		echo "$(timestamp) [INFO] Setting up port-forwarding to connect to the bastion..."
		pod="$( OC get pods --selector component=sshd -o jsonpath={.items[0].metadata.name} )"
		if ! OC port-forward "${pod}" "${1:?Port was not specified}"; then
			echo "$(timestamp) [WARNING] Port-forwarding failed, retrying..."
			sleep 0.1
		fi
	done
}

# This opens an ssh tunnel. It uses port 2222 for the ssh traffic.
# It basically says send traffic from bastion service port to
# local VM port using port 2222 to establish the ssh connection.
function ssh-tunnel() {
	while true; do
		echo "$(timestamp) [INFO] Setting up a reverse SSH tunnel to connect bastion port "${1:?Bastion service port and local service port was not specified}"..."
		if ! ssh -N -T root@127.0.0.1 -p 2222 $1; then
			echo "$(timestamp) [WARNING] SSH tunnelling failed, retrying..."
			sleep 0.1
		fi
	done
}

function pid-exists() {
	kill -0 $1 2>/dev/null
	return $?
}

trap "kill 0" SIGINT
PID_PORT=-1
PID_SSH=-1

while true; do

	if [[ ${PID_PORT} > 1 ]] && pid-exists ${PID_PORT}; then
		echo "$(timestamp) *** [WARNING] Killing old port-forward (${PID_PORT})" >> tunnel.log
		kill -9 ${PID_PORT}
	fi
	if [[ ${PID_SSH} > 1 ]] && pid-exists ${PID_SSH}; then
		echo "$(timestamp) *** [WARNING] Killing old ssh-tunnel (${PID_SSH})" >> tunnel.log
		kill -9 ${PID_SSH}
	fi

	# set up port forwarding from the SSH bastion to the local port 2222
	port-forward 2222 &
	PID_PORT=$!

	# without a better synchonization library, we just need to wait for the port-forward to run
	sleep 5s

	# run an SSH tunnel from the port on the SSH bastion (through local port 2222) to local port 
	ssh-tunnel ${PORTS} &

	PID_SSH=$!
	sleep 5s
	while true; do
		if pid-exists ${PID_PORT} && pid-exists ${PID_SSH}; then
			echo "$(timestamp) *** [INFO] Everyone up" >> tunnel.log
			sleep 10m
		else
			if ! pid-exists ${PID_PORT}; then
				echo "$(timestamp) *** [WARNING]: port-forward down!" >> tunnel.log
			fi
			if ! pid-exists ${PID_SSH}; then
				echo "$(timestamp) *** [WARNING]: ssh-tunnel down!" >> tunnel.log
			fi
			break
		fi

	done

done

for job in $( jobs -p ); do
	wait "${job}"
done

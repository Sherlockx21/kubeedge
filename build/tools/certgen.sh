#!/usr/bin/env bash

set -o errexit

readonly caPath=${CA_PATH:-/etc/kubeedge/ca}
readonly certPath=${CERT_PATH:-/etc/kubeedge/certs}
readonly subject=${SUBJECT:-/C=CN/ST=Zhejiang/L=Hangzhou/O=KubeEdge/CN=kubeedge.io}

genCA() {
    openssl genrsa -des3 -out ${caPath}/rootCA.key -passout pass:kubeedge.io 4096
    openssl req -x509 -new -nodes -key ${caPath}/rootCA.key -sha256 -days 3650 \
    -subj ${subject} -passin pass:kubeedge.io -out ${caPath}/rootCA.crt
}

ensureCA() {
    if [ ! -e ${caPath}/rootCA.key ] || [ ! -e ${caPath}/rootCA.crt ]; then
        genCA
    fi
}

ensureFolder() {
    if [ ! -d ${caPath} ]; then
        mkdir -p ${caPath}
    fi
    if [ ! -d ${certPath} ]; then
        mkdir -p ${certPath}
    fi
}

ensureCommand() {
    echo "checking if $1 command exists."
    if command -v "$1" >/dev/null 2>&1; then
        echo "$1 exists."
    else
        echo "Error: $1 not found, please install $1 command."
        exit 1
    fi
}

genCsr() {
    local name=$1
    openssl genrsa -out ${certPath}/${name}.key 2048
    openssl req -new -key ${certPath}/${name}.key -subj ${subject} -out ${certPath}/${name}.csr
}

genCert() {
    local name=$1 IPs=(${@:2})
    if  [ -z "$IPs" ] ;then
        openssl x509 -req -in ${certPath}/${name}.csr -CA ${caPath}/rootCA.crt -CAkey ${caPath}/rootCA.key \
        -CAcreateserial -passin pass:kubeedge.io -out ${certPath}/${name}.crt -days 365 -sha256
    else
        index=1
        SUBJECTALTNAME="subjectAltName = IP.1:127.0.0.1"
        for ip in ${IPs[*]}; do
            SUBJECTALTNAME="${SUBJECTALTNAME},"
            index=$(($index+1))
            SUBJECTALTNAME="${SUBJECTALTNAME}IP.${index}:${ip}"
        done
        echo $SUBJECTALTNAME > /tmp/server-extfile.cnf
        openssl x509 -req -in ${certPath}/${name}.csr -CA ${caPath}/rootCA.crt -CAkey ${caPath}/rootCA.key \
        -CAcreateserial -passin pass:kubeedge.io -out ${certPath}/${name}.crt -days 365 -sha256 -extfile /tmp/server-extfile.cnf
    fi
}

genCertAndKey() {
    ensureFolder
    ensureCA
    local name=$1
    genCsr $name
    genCert $name
}

stream() {
    ensureFolder
    ensureCommand openssl
    readonly streamsubject=${SUBJECT:-/C=CN/ST=Zhejiang/L=Hangzhou/O=KubeEdge}
    readonly STREAM_KEY_FILE=${certPath}/stream.key
    readonly STREAM_CSR_FILE=${certPath}/stream.csr
    readonly STREAM_CRT_FILE=${certPath}/stream.crt

    readonly K8SCA_FILE=${K8SCA_FILE:-/etc/kubernetes/pki/ca.crt}
    readonly K8SCA_KEY_FILE=${K8SCA_KEY_FILE:-/etc/kubernetes/pki/ca.key}

    if [ -z "${CLOUDCOREIPS}" ] && [ -z "${CLOUDCORE_DOMAINS}" ]; then
        echo "You must set at least one of CLOUDCOREIPS or CLOUDCORE_DOMAINS Env.These environment
variables are set to specify the IP addresses or domains of all cloudcore, respectively."
        echo "If there are more than one IP or domain, you need to separate them with a space within a single env."
        exit 1
    fi

    index=1
    SUBJECTALTNAME="subjectAltName = IP.1:127.0.0.1"
    for ip in ${CLOUDCOREIPS}; do
        SUBJECTALTNAME="${SUBJECTALTNAME},"
        index=$(($index+1))
        SUBJECTALTNAME="${SUBJECTALTNAME}IP.${index}:${ip}"
    done

    for domain in ${CLOUDCORE_DOMAINS};do
      SUBJECTALTNAME="${SUBJECTALTNAME},"
      SUBJECTALTNAME="${SUBJECTALTNAME}DNS:${domain}"
    done

    cp ${K8SCA_FILE} ${caPath}/streamCA.crt
    echo $SUBJECTALTNAME > /tmp/server-extfile.cnf

    openssl genrsa -out ${STREAM_KEY_FILE}  2048
    openssl req -new -key ${STREAM_KEY_FILE} -subj ${streamsubject} -out ${STREAM_CSR_FILE}

    # verify
    openssl req -in ${STREAM_CSR_FILE} -noout -text
    openssl x509 -req -in ${STREAM_CSR_FILE} -CA ${K8SCA_FILE} -CAkey ${K8SCA_KEY_FILE} -CAcreateserial -out ${STREAM_CRT_FILE} -days 5000 -sha256 -extfile /tmp/server-extfile.cnf
    #verify
    openssl x509 -in ${STREAM_CRT_FILE} -text -noout
}

opts(){
  usage() { echo "Usage: $0 [-i] ip1,ip2,..."; exit; }
  local OPTIND
  while getopts ':i:h' opt; do
    case $opt in
        i) IFS=','
           IPS=($OPTARG)
           ;;
        h) usage;;
        ?) usage;;
    esac
  done
  echo ${IPS[*]}
}

edgesiteServer(){
    serverIPs="$(opts $*)"
    if [[ $serverIPs == *"Usage:"* ]];then
        echo $serverIPs
        exit 1
    fi
    local name=edgesite-server
    ensureFolder
    ensureCA
    genCsr $name
    genCert $name $serverIPs
    genCsr server
    genCert server $serverIPs
}


edgesiteAgent(){
    ensureFolder
    ensureCA
    local name=edgesite-agent
    genCsr $name
    genCert $name
}

buildSecret() {
    local name="edge"
    genCertAndKey ${name} > /dev/null 2>&1
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudcore
  namespace: kubeedge
  labels:
    k8s-app: kubeedge
    kubeedge: cloudcore
stringData:
  rootCA.crt: |
$(pr -T -o 4 ${caPath}/rootCA.crt)
  edge.crt: |
$(pr -T -o 4 ${certPath}/${name}.crt)
  edge.key: |
$(pr -T -o 4 ${certPath}/${name}.key)

EOF
}

$@

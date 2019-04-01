#!/bin/bash

# Modify PROXY_USER to match the VSD proxy user name. Certificate file must be named <user>.pem (default proxy.pem)
PROXY_USER=tom

# Populate CRL location of external CAs used within chain
EXTERNAL_CRL_LOCATION=/root/Tom/cert_location/externalCrlLocations

KEYS_DIR=/root/Tom/cert_location/externalCrlLocations/
CRL_FILE=/root/Tom/cert_location/externalCrlLocations/crl.pem
VSPCA_FILE=/root/Tom/cert_location/externalCrlLocations/vspca.pem
TMP_CRL_FILE=/tmp/crl.pem
TMP_CONCAT_CRL_FILE=/tmp/concat_crl.pem
LAST_CRL_NUM_FILE=/root/Tom/cert_location/externalCrlLocations/lastCrlNumber.txt
EXTERNAL_CRL_LOCATION_TMP=/tmp/externalCrlLocations

GREP=/bin/egrep
OPENSSL=/usr/bin/openssl
AWK=/bin/awk
CAT=/bin/cat
SERVICE=/sbin/service
ECHO=/bin/echo
CURL=/usr/bin/curl

URL=`${OPENSSL} x509 -in ${KEYS_DIR}/${PROXY_USER}.pem -noout -text | ${GREP} cmd=crl | ${AWK} -F: '{ st = index($0,":");print substr($0,st+1)}'`

if [ "$URL" == "" ]
then
    echo "Unable to parse CRL from certificate file ${KEYS_DIR}/${PROXY_USER}.pem"
exit 1
fi

echo "" > ${TMP_CONCAT_CRL_FILE}

CRL_NO_TOTAL=0

echo DER $URL > ${EXTERNAL_CRL_LOCATION_TMP}
${GREP} -v ^# ${EXTERNAL_CRL_LOCATION} | ${GREP} -v ^$ >> ${EXTERNAL_CRL_LOCATION_TMP}

exec < ${EXTERNAL_CRL_LOCATION_TMP}
while read type url ; do
    if ${CURL} -k -o ${TMP_CRL_FILE} "$url" > /dev/null 2>&1
    then
        # Check the CRL Number
        CRL_NO_STR=`${OPENSSL} crl -inform $type -in ${TMP_CRL_FILE} -text -noout | ${GREP} -A1 'CRL Number' | ${GREP} -v "CRL Number" | tr -d ' '`
        CRL_NO=`printf '%d\n' "$CRL_NO_STR"`
        CRL_NO_TOTAL=$(($CRL_NO + $CRL_NO_TOTAL))
        ${OPENSSL} crl -in ${TMP_CRL_FILE} -inform $type >> ${TMP_CONCAT_CRL_FILE}
    else
        echo Unable to wget $url
        exit 1
    fi
done

# do we need to refresh? i.e. total CRL number changed
if [ -f ${LAST_CRL_NUM_FILE} ]; then
    # Compare the Numbers
    LAST_CRL_NO=`${CAT} ${LAST_CRL_NUM_FILE}`
    if [ "$CRL_NO_TOTAL" != "$LAST_CRL_NO" ]; then
        # The numbers are no longer matching, must reload.
        ${CAT} ${TMP_CONCAT_CRL_FILE} > ${CRL_FILE}

        ${ECHO} 'CRL Numbers no longer matching.  Reloading CRL profile.'
mv $CRL_FILE $VSPCA_FILE
sshpass -p "default" scp $VSPCA_FILE root@10.171.47.23:/tmp/
sshpass -p "default" ssh root@10.171.47.23 tmsh modify sys file ssl-crl vspca.crl source-path file:/tmp/vspca.pem
        # Update the lastCrlNumber file with the new number
        ${ECHO} $CRL_NO_TOTAL > ${LAST_CRL_NUM_FILE}
    fi
else
    # The file doesn't exist yet.  Need to reload proxy service and save the CRL Number.
    # reload haproxy config if already started
    ${CAT} ${TMP_CONCAT_CRL_FILE} > ${CRL_FILE}

      ${ECHO} 'Reloading CRL profile.'
#        tmsh modify sys file ssl-crl vspca.crl source-path file:/root/crl_location/vspca.pem
    ${ECHO} $CRL_NO_TOTAL > ${LAST_CRL_NUM_FILE}
fi

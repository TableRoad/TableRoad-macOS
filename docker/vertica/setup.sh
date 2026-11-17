#!/bin/bash
# Creates a single-node Vertica database "tableroad" (user dbadmin, no password) inside the vertica-k8s image,
# which is normally driven by the Kubernetes operator. Runs as the container's command.
set -e
cd /opt/vertica/config/https_certs
if [ ! -f vertica_https.pem ]; then
    USER=dbadmin VTMPDIR=/tmp /opt/vertica/bin/gen_httpstls_json.sh >/dev/null 2>&1
    cp rootca_cert.pem rootca.pem
    cp dbadmin_cert.pem dbadmin.pem
    cp dbadmin_key.pem dbadmin.key
    cp nma_cert.pem vertica_https.pem
    cp nma_key.pem vertica_https.key
fi
rm -f /opt/vertica/config/node_management_agent.pid
/opt/vertica/bin/manage_node_agent.sh start
sleep 5
export HOME=/home/dbadmin
if [ -d /data/tableroad ]; then
    vcluster start_db --db-name tableroad --hosts 127.0.0.1 --catalog-path /data --password "" || true
else
    vcluster create_db --db-name tableroad --hosts 127.0.0.1 --catalog-path /data --data-path /data --password ""
fi
echo "VERTICA READY"
sleep infinity

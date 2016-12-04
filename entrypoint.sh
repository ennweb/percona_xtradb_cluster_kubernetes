#!/bin/bash

set +e

HOSTNAME=`hostname`

if [ "${1:0:1}" = '-' ]; then
  set -- mysqld "$@"
fi

# if the command passed is 'mysqld' via CMD, then begin processing.
if [ "$1" = 'mysqld' ]; then
  # read DATADIR from the MySQL config
  DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

  # only check if system tables not created from mysql_install_db and permissions
  # set with initial SQL script before proceeding to build SQL script
  if [ ! -d "$DATADIR/mysql" ]; then

    echo 'Running mysqld --initialize...'
    mysqld --initialize
    chown -R mysql:mysql /var/lib/mysql
    echo 'Finished mysqld --initialize'

    # this script will be run once when MySQL first starts to set up
    # prior to creating system tables and will ensure proper user permissions
    tempSqlFile='/tmp/mysql-first-time.sql'
    cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user;
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE USER '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';
GRANT PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost';
GRANT ALL ON *.* TO '${MYSQL_PROXY_USER:-proxy}'@'%' IDENTIFIED BY '${MYSQL_PROXY_PASSWORD}';
FLUSH PRIVILEGES;
DROP DATABASE IF EXISTS test;
CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so';
CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so';
CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so';
EOSQL
    set -- "$@" --init-file="$tempSqlFile"
  fi
fi

function cluster_members() {
  SERVICE=`/kubectl describe service/pxc-cluster | grep 4567 | grep -i endpoints | awk '{print $2}'`
  SERVICE="${SERVICE//:4567/}"
  CLUSTER=$(echo $SERVICE | sed 's/,/\n/g')

  CLUSTER_MEMBERS=
  LIST=
  for server in $CLUSTER; do
    echo -n "-----> Testing potential db host $server..."
    if echo "" | nc $server 3306 | grep mysql_native_password > /dev/null; then
      echo "OK"
      LIST+="$server,"
    else
      echo "NOPE"
    fi
  done
  export CLUSTER_MEMBERS=$(echo $LIST | sed 's/,$//')
}

if [[ -z $CLUSTER_MEMBERS ]]; then
  cluster_members
fi

if [[ -z $CLUSTER_MEMBERS ]]; then
  /kubectl create configmap percona-cluster --from-literal=wsrepclusterbootstraped=0
  exitcode=$?
  
  if [ $exitcode == 0 ]; then
    SERVER_ID=1
    WSREP_CLUSTER_ADDRESS="gcomm://"
    set -- "$@" --wsrep-new-cluster
  else
    echo "-----> Waiting for primary database."
    until [[ ! -z $CLUSTER_MEMBERS ]]; do
      cluster_members
      echo -n "."
      sleep 10
    done
    echo "-----> primary ready.  Starting."
    sleep 5
  fi
fi

SERVER_ID=${RANDOM}
WSREP_CLUSTER_ADDRESS="gcomm://${CLUSTER_MEMBERS}"

WSREP_NODE_ADDRESS=`ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//'`
if [ -n "$WSREP_NODE_ADDRESS" ]; then
    sed -i -e "s/\(wsrep_node_address\=\).*$/\1$WSREP_NODE_ADDRESS/" /etc/mysql/conf.d/cluster.cnf
fi

sed -i -e "s/\(wsrep_sst_auth\=\).*/\1$WSREP_SST_USER:$WSREP_SST_PASSWORD/" /etc/mysql/conf.d/cluster.cnf
sed -i -e "s/^server\-id\s*\=\s.*$/server-id = ${SERVER_ID}/" /etc/mysql/my.cnf
sed -i -e "s|\(wsrep_cluster_address\=\).*|\1${WSREP_CLUSTER_ADDRESS}|" /etc/mysql/conf.d/cluster.cnf
sed -i -e "s/\(wsrep_node_name\=\).*/\1${HOSTNAME}/" /etc/mysql/conf.d/cluster.cnf

cat /etc/mysql/conf.d/cluster.cnf

echo "sever-id: $SERVER_ID"
echo "wsrep_cluster_address: $WSREP_CLUSTER_ADDRESS"

/kubectl delete configmap percona-cluster

# finally, start mysql
exec "$@"

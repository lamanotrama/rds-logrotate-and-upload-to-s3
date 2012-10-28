#!/bin/sh
# originally by kuroda <lamanotrama at gmail.com>
#
#
# -s でRDSのslow_logをローテートさせた後にS3にuploadする。
#
#   slow_logは一旦通常のtext形式にしてからmk-query-digestにかけて、
#   その出力もS3にupload。
#
# -g でgenericログをローテートして同様にs3にupload。
#
#
# ** 注意事項 **
#
# 全インスタンスに対して処理するよ。
#
# RDSインスタンスのエンドポイントに対して、
#   <Instance Name>.<俺のドメイン>
# でCNAMEが設定してあるという前提になっています。
# また、インスタンスが属するsecurity groupによって、そのドメインを変えるようになっ
# ているので、その辺の仕様が不要な場合は適当にコードを削ってください。
#


LANG=C

# aws-apitools用に色々ロード
source /path/to/aws-environments.sh

# $RDS_MASTERUSER_NAME $RDS_MASTERUSER_PASS をロード
source /path/to/rds-user-domain.sh

# まーここら辺は適当に変えてくれ。
PRODUCTION_DOMAIN='mydomain.jp'
STAGING_DOMAIN='mydomain.net'
VARDIR=/var/tmp/rds/log
S3BUCKET=rds-log

SLOWLOG2TEXT=$(dirname $(readlink -f $0))/rds-slowlog-to-text.pl

SLOW=
GENERAL=
DEBUG=

while getopts dsg OPT
do
    case $OPT in
    "d")
        DEBUG=1
        VARDIR=/var/tmp/_rds_debug/log
        ;;
    "s")
        SLOW=1
        ;;
    "g")
        GENERAL=1
        ;;
    *)
        (
        echo "Usage: $( basename $0 ) [OPTION]..."
        echo "  -d debug mode. rotateもs3にupもしない。出力は/var/tmp/_rds_debug/以下。"
        echo "  -s slow_logをrotate、analyze(mk-query-digest)して、s3にupload。"
        echo "  -g generic_logをrotateしてs3にupload。"
        ) 1>&2
        exit 1
        ;;
    esac
done

[ -z "$SLOW" -a -z "$GENERAL" ] && {
    echo '-s or -g required.' 1>&2
    exit 1
}

get_name_sg() {
   # apiの仕様変更でカラム数変わることあるので注意な。
   ( rds-describe-db-instances --show-long
     echo "DBINSTANCE,"
   ) | awk 'BEGIN{FS=","; RS="DBINSTANCE,";} $27~/SECGROUP/ {print $1,$28}'
}

get_suffix() {
    date '+%Y-%m-%d_%H-%M'
}

do_query() {
    ENDPOINT=$1
    QUERY=$2
    mysql -h$ENDPOINT -u $RDS_MASTERUSER_NAME -p$RDS_MASTERUSER_PASS -e "$QUERY"
}


## main //////////////
umask 077
mkdir -p $VARDIR

_IFS=$IFS
IFS='
'
for RECORD in $( get_name_sg )
do
    IFS=$_IFS
    set $( echo $RECORD )
    NAME=$1
    SG=$2

    if echo $SG | grep -q '^staging-'; then
        DOMAIN=$STAGING_DOMAIN
    else
        DOMAIN=$PRODUCTION_DOMAIN
    fi

    ENDPOINT="${NAME}.${DOMAIN}"
    LOGPATH=$VARDIR/$NAME
    SLOW_LOG=$LOGPATH/slow
    DIGEST_LOG=$LOGPATH/slow-digest
    GENERAL_LOG=$LOGPATH/general

    mkdir -p $LOGPATH

    if [ $SLOW ]; then
        (
        set -e
        SLOWLOG2TEXT_OPTS="-u $RDS_MASTERUSER_NAME -p $RDS_MASTERUSER_PASS"

        if [ ! $DEBUG ]; then
            do_query $ENDPOINT 'CALL mysql.rds_rotate_slow_log'
            SLOWLOG2TEXT_OPTS="$SLOWLOG2TEXT_OPTS -b"
        fi

        SUFFIX=$( get_suffix )
        SLOW_LOG=$SLOW_LOG.$SUFFIX.txt
        DIGEST_LOG=$DIGEST_LOG.$SUFFIX.txt

        $SLOWLOG2TEXT $SLOWLOG2TEXT_OPTS $ENDPOINT > $SLOW_LOG
        mk-query-digest --fingerprints $SLOW_LOG > $DIGEST_LOG
        )
    fi

    if [ $GENERAL ]; then
        (
        set -e
        TABLE='general_log'

        if [ ! $DEBUG ]; then
            do_query $ENDPOINT 'CALL mysql.rds_rotate_general_log'
            TABLE='general_log_backup'
        fi

        GENERAL_LOG=$GENERAL_LOG.$( get_suffix ).txt
        do_query $ENDPOINT "SELECT * FROM mysql.$TABLE" > $GENERAL_LOG
        )
    fi
done

IFS=$_IFS

[ $DEBUG ] && exit 0

s3put --bucket $S3BUCKET --prefix $VARDIR --no_overwrite --reduced --grant private $VARDIR

exit 0


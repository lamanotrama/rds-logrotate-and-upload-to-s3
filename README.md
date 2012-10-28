# rds-rotate-and-upload-to-s3

RDS(mysqlタイプ)のログテーブル(slow_log, generic_log)をローテート後にファイルに吐き出して、S3にuploadします。

### slow_log

RDSの仕様で、スロークエリログがmysql.slow_logテーブルに出力されるため、既存のツールで料理がし難い。
そのため、このツールでは一旦通常のテキストファーマットに変換しています。
また、それをmk-query-digestに食わせて、その結果も保存するようにもしています。

変換スクリプト(`rds-slowlog-to-text.p`)は単独でも使えるので、日常の調査などでも手軽に利用できると思います。



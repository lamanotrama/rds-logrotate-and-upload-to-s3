#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use DBI::Const::GetInfoType;
use Config::Pit;
use Getopt::Long qw(:config posix_default no_ignore_case gnu_compat);
use Pod::Usage;
use Config::Pit;

# ps等からパスワードを隠したい。
$0 = basename($0);

::main();
exit;


sub main {
    GetOptions(
        "backup|b"     => \my $backup,
        "user|u=s"     => \my $user,
        "password|p=s" => \my $password,
    ) or die pod2usage;

    my $table    = $backup ? 'slow_log_backup' : 'slow_log';
    my $endpoint = $ARGV[0] or die pod2usage;

    # 単体でも使いたいので、Config::Pit使えると便利。
    if ( ! $user or ! $password ) {
        $ENV{EDITOR} ||= 'vi';

        ( $user, $password ) = @{ pit_get("rds", require => {
            user     => "master username",
            password => "password of master user",
        }) }{qw/user password/};
    }

    my $dbh = DBI->connect(
        "dbi:mysql:mysql:$endpoint",
        $user,
        $password,
        +{ RaiseError => 1, AutoCommit => 0, }
    );

    my $version = $dbh->get_info( $GetInfoType{SQL_DBMS_VER} );

    print <<HEADER;
/usr/sbin/mysqld, Version: $version. started with:
Tcp port: 3306  Unix socket: /var/lib/mysql/mysql.sock
Time                 Id Command    Argument
HEADER

    my $sth = $dbh->prepare( "SELECT * FROM $table ORDER BY start_time" );
    $sth->execute();

    while (1) {
        my $rows = $sth->fetchall_arrayref( +{}, 100 )  or last;
        print as_text(%$_) for @$rows;
    }

    $dbh->disconnect;
}

sub as_text {
    my %row = @_;

   $row{time} = sprintf '%02d%02d%02d %s', $row{start_time} =~
        m/^\d{2}(\d{2})-(\d{2})-(\d{2})[ ](\d.*)$/smxo;

    for (qw/query_time lock_time/) {
        $row{$_} =~
            s{^(\d{2}):(\d{2}):(\d{2})$}
             {$1 * 36600 + $2 * 60 + $3}esxm;
    }

    $row{sql_text} .= ';' unless $row{sql_text} =~ /;\s*$/;

    my $text = <<EOT;
# Time: $row{time}
# User\@Host: $row{user_host}
# Query_time: $row{query_time}  Lock_time: $row{lock_time} Rows_sent: $row{rows_sent}  Rows_examined: $row{rows_examined}
use $row{db};
$row{sql_text}
EOT

    return $text;
}


=head1 NAME

 rds-slowlog-to-text.pl

=head1 SYNOPSIS

 rds-slowlog-to-text.pl [-b] [-u master-username] [-p password] endpoint;

=head1 DESCRIPTION

RDSのslow_logテーブルの内容を通常のファイル形式のフォーマットに変換して出力します。

master-userのidとpassはConfig::Pitでロードしますが、コマンドラインオプションで渡すことも
できます。これは、他のプログラムから実行される場合を想定しているからです。

ローテート済みのテーブル(slow_log_backup)を読みたい場合は -b付けてください。

=head1 AUTHOR

 <lamanotrama at gmail.com>

=cut


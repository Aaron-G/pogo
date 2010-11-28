#!/usr/bin/env perl -w

# Copyright (c) 2010, Yahoo! Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use 5.008;
use common::sense;

use Test::Exception;
use Test::More 'no_plan';

#use Test::More tests => 15;

use Carp qw(confess);
use Data::Dumper;
use FindBin qw($Bin);
use JSON;
use Log::Log4perl qw(:easy);
use Net::SSLeay qw();
use Sys::Hostname qw(hostname);
use Time::HiRes qw(sleep);
use YAML::XS qw(Load LoadFile);

use lib "$Bin/../lib";
use lib "$Bin/lib";

use PogoTester qw(derp);

use Pogo::Engine;
use Pogo::Engine::Job;
use Pogo::Engine::Store qw(store);

$SIG{ALRM} = sub { confess; };
alarm(60);

ok( my $pt = PogoTester->new(), "new pt" );

chdir($Bin);

ok( Log::Log4perl::init("$Bin/conf/log4perl.conf"), "log4perl" );

my $js = JSON->new;
my $t;

# start pogo-dispatcher
my $stopped = 0;
my $pid;
ok( $pid = $pt->start_dispatcher, "start dispatcher $pid" );
END { kill 15, $pid unless $stopped; }

my $conf;
$conf = LoadFile("$Bin/conf/dispatcher.conf");
ok( !$@, "loadconf" );

# ping
$t = $pt->dispatcher_rpc( ["ping"] );
ok( $t->[1]->[0] == 0xDEADBEEF, 'ping' )
  or print Dumper $t;

# stats
$t = $pt->dispatcher_rpc( ["stats"] );
ok( $t->[1]->[0]->{hostname} eq hostname(), 'stats' )
  or print Dumper $t;

# ensure no workers are connected
foreach my $dispatcher ( @{ $t->[1] } )
{
  ok( exists $dispatcher->{workers_idle}, "exists workers_idle" )
    or print Dumper $dispatcher;
  ok( exists $dispatcher->{workers_busy}, "exists workers_busy" )
    or print Dumper $dispatcher;
  ok( $dispatcher->{workers_idle} == 0, "zero workers_idle" )
    or LOGDIE "eek! bailing, don't want to *actually* run tasks";
  ok( $dispatcher->{workers_busy} == 0, "zero workers_busy" )
    or LOGDIE "eek! bailing, don't want to *actually* run tasks";
}

# loadconf
my $conf_to_load = LoadFile("$Bin/conf/example.yaml");
$t = $pt->dispatcher_rpc( [ "loadconf", 'example', $conf_to_load ] )
  or print Dumper $t;
ok( $t->[0]->{status} eq 'OK', "loadconf rpc OK" ) or print Dumper $t;

# get our local store up (dispatcher process's is separate)
ok( Pogo::Engine::Store->init($conf), "store up" );

# start a job
my %job1 = (
  user        => 'test',
  run_as      => 'test',
  command     => 'echo job1',
  target      => [ 'foo[1-10].example.com', ],
  namespace   => 'example',
  password    => 'foo',
  timeout     => 3,
  job_timeout => 3,
  concurrent  => 1,
);

ok( my $job = Pogo::Engine::Job->new( \%job1 ), "job->new" );

#$job->start( sub { ok( 1, "started" ); confess; }, sub { ok( 0, "started" ); confess; } );
#$job->start( sub { ok( 0, "started" ); }, sub { ok( 1, "started" ); } );
sleep 3.5;
ok( $job->state eq 'halted', 'job timeout' );

# stop
ok( $pt->stop_dispatcher, 'stop dispatcher' ) and $stopped = 1;

1;

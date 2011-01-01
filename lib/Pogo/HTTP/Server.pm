package Pogo::HTTP::Server;

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

use Data::Dumper;

use 5.008;
use common::sense;

use AnyEvent::HTTPD;
use Carp;
use JSON::XS;
use Log::Log4perl qw(:easy);
use MIME::Types qw(by_suffix);
use Template;

my $instance;
my $HOST_COUNT_CACHE = {};

# ::Server - pogo's built-in http server
# 1. dispatch api requests at /api/vX (currently always 3)
#    api requests are currently syncronous, we should probably pass a callback along
#    this is made difficult by many of the methods taking variable arguments.
#
# 2. serve static content from /static
#
# 3. respond to UI requests - any other url is handled by the UI handler
#    Template.pm is used to generate a job index at /, and /p\d+ or /\d+ urls are
#    interpreted as jobids
#
# handle_* subs need $httpd and $request and are expected
# to $request->respond() and $httpd->stop_request()
# ui_(*) are subs for requests to /$1

# {{{ constructors

sub run
{
  Carp::croak "Server already running" if $instance;
  my $class = shift;
  $instance = {@_};
  bless $instance, $class;

  $instance->{httpd} = AnyEvent::HTTPD->new(
    host            => $instance->{bind_address},
    port            => $instance->{http_port},
    request_timeout => 10,
  );

  # note that due to the way that AnyEvent::HTTPD works, any handlers must
  # call $httpd->stop_request, or events will be generated for all handlers that match
  # the request
  $instance->{httpd}->reg_cb(
    '/favicon.ico' => sub { handle_favicon(@_); },    # just a hack to 301 /favicon to /static
    '/static'      => sub { handle_static(@_); },
    '/api'         => sub { handle_api(@_) },
    ''             => sub { handle_ui(@_) },
  );

  $instance->{tt} ||= Template->new( { INCLUDE_PATH => $instance->{template_path}, DEBUG => 1 } );

  INFO sprintf(
    "Accepting HTTP requests on %s:%s",
    $instance->{httpd}->host,
    $instance->{httpd}->port
  );
}

# }}}
# {{{ handle_api

sub handle_api
{
  my ( $httpd, $request ) = @_;
  INFO sprintf( 'Received HTTP request for %s from %s:%d',
    $request->url, $request->client_host, $request->client_port );

  # Set these to some defaults in case an exception is raised.
  my $response         = Pogo::Engine::Response->new;
  my $response_format  = $request->parm('format') || 'json-pretty';
  my $response_headers = {
      'Content-Type' => $response_format eq 'yaml'
    ? 'text/plain'
    : 'text/javascript'
  };

  # we eval this whole block as a request to handle; any die()'s within the
  # block are properly logged/responded to below
  eval {
    my ( undef, undef, $version, $method ) = split( '/', $request->url );
    $version = uc($version);
    die "Unsupported version '$version'" . $request->url unless $version =~ /^v\d+/i;

    # Dynamically load the API module
    my $class = "Pogo::API::$version";
    eval "require $class";
    die $@ if $@;

    if ($method)
    {
      ();    # TODO: Add supported REST methods
    }
    else     # RPC request
    {
      if ( $request->parm('r') )
      {
        die "c/v mutually exclusive"
          if $request->parm('c') && $request->parm('v');

        my $req = JSON::XS::decode_json( $request->parm('r') );
        my ( $action, @args ) = @$req;

        # TODO: pass callback
        $response = $class->$action(@args);

        $response->add_header( action => $action );
        $response->set_format($response_format);
        $response->set_callback( $request->parm('c') ) if $request->parm('c');
        $response->set_pushvar( $request->parm('v') )  if $request->parm('v');

        $request->respond( [ 200, 'OK', $response_headers, $response->content ] );
      }
    }
  };
  if ($@)
  {
    chomp( my $errmsg = $@ );
    ERROR $errmsg;
    my $error = Pogo::Engine::Response->new;
    $error->set_format($response_format);
    $error->set_error($errmsg);
    $request->respond( [ 500, 'OK', $response_headers, $error->content ] );
  }
  $httpd->stop_request();
}

# }}}
# {{{ handle_static

# static content is served from 'static_path' in the dispatcher.conf
# we try to be reasonably careful here about not serving random files
sub handle_static
{
  my ( $httpd, $request ) = @_;
  INFO sprintf( 'Received HTTP request for %s from %s:%d',
    $request->url, $request->client_host, $request->client_port );

  my $response_headers = { 'Content-type' => 'application/octet-stream', };

  if ( !defined $instance->{static_path}
    || !-d $instance->{static_path}
    || !-r $instance->{static_path} )
  {
    ERROR "no static path?";
    return handle_ui_error( $httpd, $request, "not found" );
  }

  if ( $request->url =~ m{\.\.} )
  {
    ERROR "suspicious url: " . $request->url;
    return handle_ui_error( $httpd, $request, "foo" );
  }

  my $path = $request->url;
  $path =~ s/^\/static//;

  my $filepath = $instance->{static_path} . $path;

  if ( !-f $filepath || !-r $filepath )
  {
    return handle_ui_error( $httpd, $request, $request->url . " not found" );
  }

  my $size = -s $filepath;

  if ( $size > 102400 )
  {
    return handle_ui_error( $httpd, $request, "too big" );
  }

  $response_headers->{'Content-length'} = $size;
  $response_headers->{'Content-type'}   = by_suffix($filepath);

  {
    open my $fh, '<', $filepath
      or confess "couldn't open file";
    $request->respond(
      [ 200, 'OK', $response_headers,
        do { local $/; <$fh>; }
      ]
    );
    close $fh
      or confess "couldn't close file";
  }

  $httpd->stop_request();
}

# }}}
# {{{ handle_favicon

# quick hack for redirecting favicon requests
sub handle_favicon
{
  my ( $httpd, $request ) = @_;
  $request->respond(
    [ 301,
      'Moved Permanently',
      { 'Location' => '/static/favicon.png' },
      '<html><head><title>Moved Permanently</title></head><body><a href="/static/favicon.png">Moved Permanently</a></body></html>'
    ]
  );
  $httpd->stop_request();
}

# }}}
# {{{ handle_async_request

# handle_async should eventually supplant handle_api
# essentially it's a copy that supports callbacks
sub handle_async
{
  my ( $httpd, $request ) = @_;
  if ( $request->parm('r') )
  {
    INFO sprintf( 'Received async HTTP request for %s from %s:%d - %s',
      $request->url, $request->client_host, $request->client_port, $request->parm('r') );
  }
  else
  {
    INFO sprintf( 'Received async HTTP request for %s from %s:%d',
      $request->url, $request->client_host, $request->client_port );
  }

  my $response_format = $request->parm('format') || 'json';
  my $response_headers = {
      'Content-Type' => $response_format eq 'yaml'
    ? 'text/plain'
    : 'text/javascript'
  };

  my $response_callback = sub {
    my ($response) = @_;

    $response->set_format($response_format);
    $response->set_callback( $request->parm('c') ) if $request->parm('c');
    $response->set_pushvar( $request->parm('v') )  if $request->parm('v');

    if ( $response->is_success )
    {
      $request->respond( [ 200, 'OK', $response_headers, $response->content ] );
    }
    else
    {
      $request->respond( [ 500, 'ERROR', $response_headers, $response->content ] );
    }
  };

  eval {
    my ( undef, undef, $version, $method ) = split( '/', $request->url );
    $version = uc($version);
    die "Unsupported version '$version'" unless $version =~ /^v\d+/i;

    # Dynamically load the API module
    my $class = "Pogo::API::$version";
    eval "require $class";
    die $@ if $@;

    if ($method)
    {
      ();    # TODO: Add supported REST methods
    }
    else     # RPC request
    {
      DEBUG "request=" . $request->parm('r');
      if ( $request->parm('r') )
      {
        die "c/v mutually exclusive"
          if $request->parm('c') && $request->parm('v');
        my $req = JSON::XS::decode_json( $request->parm('r') );
        my ( $action, @args ) = @$req;
        $class->$action( @args, $response_callback );
      }
    }
  };
  if ($@)
  {
    chomp( my $errmsg = $@ );
    ERROR $errmsg;
    my $error = Pogo::Engine::Response->new;
    $error->set_format($response_format);
    $error->set_error($errmsg);
    $request->respond( [ 500, 'OK', $response_headers, $error->content ] );
  }
  $httpd->stop_request();
}

# }}}
# {{{ handle_ui

sub handle_ui
{
  my ( $httpd, $request ) = @_;
  my $response_headers = { 'Content-type: text/html', };

  INFO sprintf( 'Received HTTP request for %s from %s:%d',
    $request->url, $request->client_host, $request->client_port );

  # extract our command or jobid from url, falling back to index.
  my ( undef, $method, @args ) = split( '/', $request->url );

  my $ocmd = ( split( m{/}, $method ) )[-1] || 'index';
  my $cmd = "ui_${ocmd}";
  my @args;

  # if the requested method isn't valid, see if it's a jobid instead
  eval {
    if ( !$instance->can($cmd) )
    {
      my $jobid = to_jobid($ocmd);

      # perhaps we should redirect to the correct jobid url here
      # if to_jobid() modifies the jobid
      if ($jobid)
      {
        $cmd = 'ui_status';
        push @args, $jobid;
      }
      else
      {
        confess "invalid method";
      }
    }

    # execute our requested method or die trying
    $instance->$cmd( $request, @args );
  };

  if ($@)
  {
    ERROR sprintf( "encountered an error with '%s': %s", $request->url, $@ );
    handle_ui_error( $httpd, $request, $@ ) if $@;
  }
  $httpd->stop_request();
}

# }}}
# {{{ handle_ui_error

# any ui errors
sub handle_ui_error
{
  my ( $httpd, $request, $error ) = @_;
  $instance->{tt}->process(
    'error.tt',
    { error => $error, page_title => 'ERROR', },
    sub {
      my $output = shift;
      $request->respond( [ 500, 'ERROR', { 'Content-type' => 'text/html' }, $output ] );
    },
    )
    or $request->respond(
    [ 500, 'ERROR', { 'Content-type' => 'text/plain' }, "an unknown error occurred" ] );
  $httpd->stop_request();
}

# }}}
# {{{ ui_status

# individual job status, needs a jobid
sub ui_status
{
  my ( $self, $request, $jobid ) = @_;

  $jobid =~ m{^[a-z]\d+$}i || die "bad jobid $jobid\n";
  my $resp = Pogo::Engine->jobinfo($jobid);
  if ( !$resp->is_success )
  {
    die "Couldn't fetch jobinfo for $jobid: " . $resp->status_msg . "\n";
  }

  my $data = {
    page_title => 'job status: ' . $jobid,
    jobid      => $jobid,
    jobinfo    => $resp->record,
    pogo_api =>
      sprintf( "http://%s:%s/api/v3", $instance->{httpd}->host, $instance->{httpd}->port ),
  };

  DEBUG Dumper $data;

  $instance->{tt}->process(
    'status.tt',
    $data,
    sub {
      my $output = shift;
      $request->respond( [ 200, 'OK', { 'Content-type' => 'text/html' }, $output ] );
    },
  );
}

# }}}
# {{{ ui_index

# the main job index, paginated
sub ui_index
{
  my ( $self, $request, @args ) = @_;

  my $jobs_per_page = $request->parm('max') || 25;

  # initialize filters
  my %filters;
  foreach my $f (qw(user state target))
  {
    my $value = $request->parm($f);
    $filters{$f} = $value if defined $value;
  }

  # calculate the offset
  my $req_page = $request->parm('cur') || 1;
  my $offset = ( $req_page - 1 ) * $jobs_per_page;
  $filters{offset} = $offset if $offset;

  # determine the total number of jobs
  my $max_jobid = _list_jobs( offset => 0, limit => 2 )->[0]->{jobid};
  my $num_jobs = $jobs_per_page;
  if ( $max_jobid =~ m/^p(\d+)$/ )
  {
    $num_jobs = int($1) - $instance->{jobid_offset};
  }

  DEBUG "max_jobid=$max_jobid, num_jobs=$num_jobs";

  # build our data
  my $data = {
    page_title => 'job index',
    jobs       => _list_jobs( page => $req_page, limit => $jobs_per_page, %filters ),
    running_jobs  => _list_jobs( state => 'running' ),
    jobs_per_page => $jobs_per_page,
    num_jobs      => $num_jobs,
    req_page      => $req_page,
    %filters
  };

  $data->{pager} = _paginate($data);

  $instance->{tt}->process(
    'index.tt',
    $data,
    sub {
      my $output = shift;
      $request->respond( [ 200, 'OK', { 'Content-type' => 'text/html' }, $output ] );
    },
  );
}

sub _list_jobs
{
  my (%filters) = @_;

  my $req_page = delete $filters{page} || 1;

  my $resp = Pogo::Engine->listjobs(%filters);

  # reformat the output
  my @jobs = $resp->records;
  my $num_jobs = @jobs > 0 ? int( substr( $jobs[0]->{jobid}, 1 ) ) : 0;

  for ( my $i = 0; $i < @jobs; $i++ )
  {

    # deserialize the target list
    $jobs[$i]->{target} = JSON::XS::decode_json( $jobs[$i]->{target} );
    $jobs[$i]->{target_list} = join( ',', @{ $jobs[$i]->{target} } );

    # format the start time
    my $start_time = '';
    my $start_ts   = $jobs[$i]->{start_time};
    if ($start_ts)
    {
      my @t = localtime($start_ts);
      $start_time = sprintf(
        "%04d-%02d-%02dT%02d:%02d:%02d",
        $t[5] + 1900,
        $t[4] + 1,
        $t[3], $t[2], $t[1], $t[0]
      );
    }
    $jobs[$i]->{start_ts}   = $start_ts;
    $jobs[$i]->{start_time} = $start_time;

    # determine the host count
    $jobs[$i]->{host_count} = _get_host_count( $jobs[$i]->{jobid} );
  }

  return \@jobs;
}

sub _get_host_count
{
  my ($jobid) = @_;

  unless ( exists $HOST_COUNT_CACHE->{$jobid} )
  {
    my $resp = Pogo::Engine->jobstatus($jobid);
    my ( $jobstate, @hosts ) = $resp->records;
    $HOST_COUNT_CACHE->{$jobid} = scalar @hosts;
  }

  return $HOST_COUNT_CACHE->{$jobid};
}

sub _paginate
{
  my ($data) = @_;

  my $jobs_per_page = $data->{jobs_per_page};
  my $req_page      = $data->{req_page};
  my $num_jobs      = $data->{num_jobs};
  my %pager;

  if ( $num_jobs > $jobs_per_page )
  {
    my $last_page = int( ( $num_jobs + $jobs_per_page - 1 ) / $jobs_per_page );
    my $prev_page = max( 1, $req_page - 1 );
    my $next_page = min( $last_page, $req_page + 1 );
    my $min_page = max( 1, $req_page - 5 );
    my $max_page = min( $last_page, $min_page + 9 );
    my $offset   = 0;
    my @pages    = map { { number => $_ } } ( $min_page .. $max_page );

    %pager = (
      cur       => $req_page,
      pages     => \@pages,
      prev_page => $prev_page,
      next_page => $next_page,
      last_page => $last_page
    );
  }

  return \%pager;
}

# }}}
# {{{ misc

# simple helper function to convert user-supplied string to a jobid.
# TODO: move to Pogo::Common?  I think this is duplicated in the
# client.
sub to_jobid
{
  my ($jobid) = @_;

  my $p = 'p';
  my $i;

  if ( $jobid eq 'last' )
  {
    ();    # TODO: how do we determine user?
  }

  if ( $jobid =~ m/^([a-z]+)(\d+)$/ )
  {
    $p = $1;
    $i = $2;
  }
  elsif ( $jobid =~ m/^(\d+)$/ )
  {
    $i = $1;
  }

  my $new_jobid;
  if ( defined $i )
  {
    $new_jobid = sprintf "%s%010d", $p, $i;
  }
  else
  {
    die "jobid not found\n";
  }

  return $new_jobid;
}

# }}}

1;

=pod

=head1 NAME

  CLASSNAME - SHORT DESCRIPTION

=head1 SYNOPSIS

CODE GOES HERE

=head1 DESCRIPTION

LONG_DESCRIPTION

=head1 METHODS

B<methodexample>

=over 2

methoddescription

=back

=head1 SEE ALSO

L<Pogo::Dispatcher>

=head1 COPYRIGHT

Apache 2.0

=head1 AUTHORS

  Andrew Sloane <asloane@yahoo-inc.com>
  Michael Fischer <mfischer@yahoo-inc.com>
  Nicholas Harteau <nrh@yahoo-inc.com>
  Nick Purvis <nep@yahoo-inc.com>
  Robert Phan <rphan@yahoo-inc.com>

=cut

# vim:syn=perl:sw=2:ts=2:sts=2:et:fdm=marker

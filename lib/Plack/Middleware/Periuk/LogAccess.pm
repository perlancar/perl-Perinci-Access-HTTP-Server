package Plack::Middleware::Periuk::LogAccess;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(
                                log_path
                                max_args_len
                                max_resp_len
                        );

use JSON;
use Plack::Util;
use POSIX;
use Time::HiRes qw(gettimeofday tv_interval);

# VERSION

sub prepare_app {
    my $self = shift;
    if (!$self->log_path) {
        die "Please specify log_path";
    }

    $self->{max_args_len} //= 1000;
    $self->{max_resp_len} //= 1000;

    open my($fh), ">>", $self->log_path
        or die "Can't open log file `$self->{log_path}`: $!";
    $self->{_log_fh} = $fh;
}

sub call {
    my ($self, $env) = @_;

    $env->{'ss.start_request_time'} = time();

    # call app first
    my $res = $self->app->($env);
    return $self->response_cb(
        $res,
        sub {
            my $res = shift;
            $self->log_access($env);
        });

    $res;
}

sub log_access {
    my ($self, $env) = @_;

    my $now = [gettimeofday];

    return unless $env->{'ss.start_command_time'};

    my $time = POSIX::strftime("%d/%b/%Y:%H:%M:%S +0000",
                               gmtime($env->{'ss.start_request_time'}));
    my $server_addr;
    if ($env->{'gepok.unix_socket'}) {
        $server_addr = "unix:$env->{SERVER_NAME}";
    } else {
        $server_addr = "tcp:$env->{SERVER_PORT}";
    }

    state $json = JSON->new->allow_nonref;

    my ($args_s, $args_len, $args_partial);
    if ($env->{'ss.request'}{args}) {
        $args_s = $json->encode($env->{'ss.request'}{args});
        $args_len = length($args_s);
        $args_partial = $args_len > $self->max_args_len;
        $args_s = substr($args_s, 0, $self->max_args_len)
            if $args_partial;
    } else {
        $args_s = "";
        $args_len = 0;
        $args_partial = 0;
    }

    my ($resp_s, $resp_len, $resp_partial);
    if ($env->{'ss.response'}) {
        $resp_s = $json->encode($env->{'ss.response'});
        $resp_len = length($resp_s);
        $resp_partial = $resp_len > $self->max_resp_len;
        $resp_s = substr($resp_s, 0, $self->max_resp_len)
            if $resp_partial;
    } else {
        $resp_s = "";
        $resp_partial = 0;
        $resp_len = 0;
    }

    my $subt;
    if ($env->{'ss.start_command_time'}) {
        if ($env->{'ss.finish_command_time'}) {
            $subt = sprintf("%.3fms",
                            1000*tv_interval($env->{'ss.start_command_time'},
                                             $env->{'ss.finish_command_time'}));
        } else {
            $subt = "D";
        }
    } else {
        $subt = "-";
    }

    my $reqt;
    if ($env->{'gepok.connect_time'}) {
        $reqt = sprintf("%.3fms",
                        1000*tv_interval($env->{'gepok.start_request_time'},
                                         $now));
    } else {
        $reqt = "-";
    }

    my $extra = "";

    my $fmt = join(
        "",
        "[%s] ", # time
        "[%s] ", # remote addr
        "[%s] ", # server addr
        "[user %s] ",
        "%s %s ", # command uri
        "[args %s %s] ",
        "[resp %s %s] ",
        "%s %s", # subt reqt
        "%s", # extra info
        "\n"
    );

    my $uri = $env->{'ss.request'}{uri};
    my $log_line = sprintf(
        $fmt,
        $time,
        $env->{REMOTE_ADDR},
        $server_addr,
        $env->{HTTP_USER} // "-",
        _safe($env->{'ss.request'}{command}),
        _safe(ref($uri) ? $uri->{_uri} : ($uri // "-")),
        $args_len.($args_partial ? "p" : ""), $args_s,
        $resp_len.($resp_partial ? "p" : ""), $resp_s,
        $subt, $reqt,
        $extra,
    );

    #warn $log_line;
    syswrite $self->{_log_fh}, $log_line;
}

sub _safe {
    my $string = shift;
    $string =~ s/([^[:print:]])/"\\x" . unpack("H*", $1)/eg
        if defined $string;
    $string;
}

1;
# ABSTRACT: Log request
__END__

=head1 SYNOPSIS

 # In app.psgi
 use Plack::Builder;

 builder {
     enable "Periuk::LogAccess", log_path => "/path/to/api-access.log";
 }


=head1 DESCRIPTION

This middleware forwards the request to given app and logs request. Only
requests which have executed commands (has $env->{'ss.start_command_time'} set)
will be logged.

The log looks like this (all in one line):

 [20/Aug/2011:22:05:38 +0000] [127.0.0.1] [tcp:80] [libby] call
 pm://MyModule/my_func [args 14 {"name":"val"}] [resp 12 [200,"OK",1]]
 2.123ms 5.947ms

The second last time is time spent executing the command (in this case, calling
the subroutine), and the last time is time spent for the whole request (from
client connect until response is sent).


=head1 CONFIGURATION

=over 4

=item * log_path

Path to log file. Log file will be opened in append-mode.

=item * max_args_len => INT (default 1000)

Maximum number of characters of args to log. Args will be JSON-encoded and
truncated to this value if too long. In the log file it will be printed as:

 [args <LENGTH> <ARGS>]

=item * max_resp_len => INT (default 1000)

Maximum number of characters of sub response to log. Response will be
JSON-encoded and truncated to this value if too long. In the log file it will be
printed as:

 [resp <LENGTH> <ARGS>]

=back

=cut

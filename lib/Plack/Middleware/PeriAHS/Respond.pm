package Plack::Middleware::PeriAHS::Respond;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(
                                time_limit
                        );

use Data::Rmap;
use Log::Any::Adapter;
use Plack::Util::PeriAHS qw(errpage allowed);
use Scalar::Util qw(blessed);
use Time::HiRes qw(gettimeofday);

# VERSION

sub prepare_app {
    my $self = shift;
    $self->{allowed_output_formats} //= [qw/html json phps yaml/];
}

sub _pick_default_format {
    my ($self, $env) = @_;
    # if client is a GUI browser, choose html. otherwise, json.
    my $ua = $env->{HTTP_USER_AGENT} // "";
    return "html" if $ua =~ m!Mozilla/|Opera/!;
    # mozilla already includes ff, chrome, safari, msie
    "json";
}

sub format_json {
    my ($self, $sub_res, $env) = @_;
    require Data::Format::Pretty::JSON;
    my $json = Data::Format::Pretty::JSON::format_pretty($sub_res, {pretty=>0});
    return (
        defined($env->{_jsonp_callback}) ?
            "$env->{_jsonp_callback}($json)" :
                $json,
        "application/json"
    );
}

sub format_yaml {
    my ($self, $sub_res, $env) = @_;
    require Data::Format::Pretty::YAML;
    return (Data::Format::Pretty::YAML::format_pretty($sub_res),
            "text/yaml");
}

sub format_phps {
    my ($self, $sub_res, $env) = @_;
    require Data::Format::Pretty::PHPSerialization;
    return (Data::Format::Pretty::PHP::format_pretty($sub_res),
            "application/vnd.php.serialized");
}

sub format_html {
    my ($self, $sub_res, $env) = @_;
    require Data::Format::Pretty::HTML;
    return (Data::Format::Pretty::HTML::format_pretty($sub_res),
            "text/html");
}

sub call {
    my ($self, $env) = @_;

    die "This middleware needs psgi.streaming support"
        unless $env->{'psgi.streaming'};

    my $rreq = $env->{"riap.request"};

    my $ofmt = $rreq->{output_format} // $self->default_output_format
        // $self->_pick_default_format($env);
    return errpage("Unknown output format: $ofmt")
        unless $ofmt =~ /^\w+/ && $self->can("format_$ofmt");
    return errpage("Output format $ofmt not allowed")
        unless allowed($ofmt, $self->allowed_output_formats);

    return sub {
        my $respond = shift;

        my $writer;
        my $loglvl  = $rreq->{'loglevel'};
        my $marklog = $rreq->{'marklog'};
        my $res;
        if ($loglvl) {
            $writer = $respond->([200, ["Content-Type" => "text/plain"]]);
            Log::Any::Adapter->set(
                {lexically=>\my $lex},
                "Callback",
                min_level => $loglvl,
                logging_cb => sub {
                    my ($method, $self, $format, @params) = @_;
                    my $msg = join(
                        "",
                        $marklog ? "L" : "",
                        "[$method]",
                        "[", scalar(localtime), "] ",
                        $format, "\n");
                    $writer->write($msg);
                },
            );
            $res = ;
        } else {
            $res = $exec_cmd->();
        }

        $self->postprocess_result($cmd_res);

        $env->{'riap.response'} = $res;

        my $fmt_method = "format_$ofmt";
        my ($res, $ct) = $self->$fmt_method($cmd_res, $env);

        if ($writer) {
            $writer->write($marklog ? "R$res" : $res);
            $writer->close;
        } else {
            $respond->([200, ["Content-Type" => $ct], [$res]]);
        }
    };
}

1;
# ABSTRACT: Send Riap request

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     enable "PeriAHS::Request";
 };


=head1 DESCRIPTION

This middleware sends Riap request (C<$env->{"riap.request"}>) to Riap client
(L<Perinci::Access>). This middleware is the "meat" of the application and
should be put after all the parsing, authentication, and authorization
middlewares.

The result will be put in C<$env->{"riap.response"}>.


=head1 CONFIGURATIONS

=over 4

=item * default_output_format => STR, default 'json'

The default format to use if client does not specify 'output_format' SS request
key.

If unspecified, some detection logic will be done to determine default format:
if client is a GUI browser, 'html'; otherwise, 'json'.

=item * allowed_output_formats => ARRAY|REGEX (default [qw/html json phps yaml/])

Specify what output formats are allowed. When client requests an unallowed
format, 400 error is returned.

=item * time_limit => INT | CODE

Impose time limit, using alarm(). If coderef is given, it will be called for
every request with ($self, $env) argument and expected to return the time limit.

=back

=cut

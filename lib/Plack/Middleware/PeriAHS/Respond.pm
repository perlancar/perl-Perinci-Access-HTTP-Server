package Plack::Middleware::PeriAHS::Respond;

use 5.010;
use strict;
use warnings;

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw();

use Data::Rmap;
use Log::Any::Adapter;
use Perinci::Result::Format;
use Plack::Util::PeriAHS qw(errpage allowed);
use Scalar::Util qw(blessed);
use Time::HiRes qw(gettimeofday);

# VERSION

sub prepare_app {
    my $self = shift;
}

sub format_result {
    my ($self, $rres, $env) = @_;

    my $rreq = $env->{"riap.request"};
    my $fmt = $rreq->{fmt} // $env->{'periahs.default_fmt'} // 'json';

    my $formatter;
    for ($fmt, "json") { # fallback to json if unknown format
        $formatter = $Perinci::Result::Format::Formats{$_};
        if ($formatter) {
            $fmt = $_;
            last;
        }
    }
    my $ct = $formatter->[1];

    my $fres = Perinci::Result::Format::format($fmt, $rres);

    if ($fmt =~ /^json/ && defined($env->{"periahs.jsonp_callback"})) {
        $fres = $env->{"periahs.jsonp_callback"}."($json)";
    );

    ($fres, $ct);
}

sub call {
    my ($self, $env) = @_;

    die "This middleware needs psgi.streaming support"
        unless $env->{'psgi.streaming'};

    my $rreq = $env->{"riap.request"};
    my $pa   = $env->{"periahs.riap_client"};

    return sub {
        my $respond = shift;

        my $writer;
        my $loglvl  = $rreq->{'loglevel'};
        my $marklog = $rreq->{'marklog'};
        my $rres; #  short for riap response
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
            $rres = $pa->request($rreq->{action} => $rreq->{uri}, $rreq);
        } else {
            $rres = $pa->request($rreq->{action} => $rreq->{uri}, $rreq);
        }

        $env->{'riap.response'} = $rres;
        my ($fres, $ct) = $self->format_result($rres, $env);

        if ($writer) {
            $writer->write($marklog ? "R$res" : $res);
            $writer->close;
        } else {
            $respond->([200, ["Content-Type" => $ct], [$res]]);
        }
    };
}

1;
# ABSTRACT: Send Riap request to Riap server and send the response to client

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     enable "PeriAHS::Respond";
 };


=head1 DESCRIPTION

This middleware sends Riap request (C<$env->{"riap.request"}>) to Riap client
(L<Perinci::Access> object, stored in C<$env->{"periahs.riap_client"}> by
PeriAHS::ParseRequest middleware), format the result, and send it to client.
This middleware is the one that sends response to client and should be put as
the last middleware after all the parsing, authentication, and authorization
middlewares.

The result will also be put in C<$env->{"riap.response"}>.


=head1 CONFIGURATIONS

=over 4

=back

=cut

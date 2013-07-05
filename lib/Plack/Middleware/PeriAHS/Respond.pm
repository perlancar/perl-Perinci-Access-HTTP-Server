package Plack::Middleware::PeriAHS::Respond;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use parent qw(Plack::Middleware);
use Plack::Util::Accessor qw(
                                add_text_tips
                        );

use Log::Any::Adapter;
use Perinci::Result::Format 0.31;
use Scalar::Util qw(blessed);
use Time::HiRes qw(gettimeofday);

# VERSION

# to avoid sending colored YAML/JSON output
$Perinci::Result::Format::Enable_Decoration = 0;

# to allow in-place cleansing of data when formatter can't handle data
$Perinci::Result::Format::Enable_Cleansing = 1;

sub prepare_app {
    my $self = shift;

    $self->{add_text_tips} //= 1;
}

sub format_result {
    my ($self, $rres, $env) = @_;

    my $midpr = $env->{"middleware.PeriAHS.ParseRequest"};
    my $rreq = $env->{"riap.request"};

    # adjust entity uri's against riap_uri_prefix configuration
    if ($rreq->{action} eq 'list' && $rres->[0] == 200) {
        for my $e (@{ $rres->[2] }) {
            for ($rreq->{detail} ? $e->{uri} : $e) {
                if (s/^pl://) {
                    s/\A\Q$midpr->{riap_uri_prefix}//;
                }
            }
        }
    }

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

    my $fres = Perinci::Result::Format::format($rres, $fmt);

    if ($fmt =~ /^json/ && defined($env->{"periahs.jsonp_callback"})) {
        $fres = $env->{"periahs.jsonp_callback"}."($fres)";
    }

    if ($self->{add_text_tips} && $fmt =~ /^text/ && !ref($fres)) {
        my @tips;
        my $pf = $midpr->{parse_form};
        if ($rreq->{action} eq 'list') {
            my (@f, @p);
            if ($rreq->{detail}) {
                @f = grep {$_->{type} eq 'function'} @{$rres->[2]};
                @p = grep {$_->{type} eq 'package' } @{$rres->[2]};
            }
            if (@f) {
                local $rreq->{uri} = "pl:$midpr->{riap_uri_prefix}".$f[rand(@f)]{uri};
                push @tips, "* To call a function, try:\n    ".
                    $midpr->{get_http_request_url}->($midpr, $env, $rreq);
                if ($pf) {
                    push @tips, "* Function arguments can be given via GET/POST params or JSON hash in req body";
                } else {
                    push @tips, "* Function arguments can be given via JSON hash in request body";
                }
                $rreq->{uri} = "pl:$midpr->{riap_uri_prefix}".$f[rand(@f)]{uri};
                my $url = $midpr->{get_http_request_url}->($midpr, $env, $rreq);
                push @tips, "* To find out which arguments a function supports, try:\n    ".
                    ($pf ? "$url?-riap-action=meta" : "curl -H 'x-riap-action: meta' $url");
            }
            if (@p) {
                local $rreq->{uri} = "pl:$midpr->{riap_uri_prefix}".$p[rand(@p)]{uri};
                push @tips, "* To list the content of a (sub)package, try:\n    ".
                    $midpr->{get_http_request_url}->($midpr, $env, $rreq);
            }
            if ($rreq->{detail} && @{$rres->[2]}) {
                local $rreq->{uri} = "pl:$midpr->{riap_uri_prefix}".$rres->[2][rand(@{ $rres->[2] })]{uri};
                my $url = $midpr->{get_http_request_url}->($midpr, $env, $rreq);
                push @tips, "* To find out all available actions on an entity, try:\n    ".
                    ($pf ? "$url?-riap-action=actions" : "curl -H 'x-riap-action: actions' $url");
            }
            push @tips,"* This server uses Riap protocol for great autodiscoverability, for more info:\n".
                "    https://metacpan.org/module/Riap";
        }
        if (@tips) {
            $fres .= "\nTips:\n".join("\n", @tips)."\n";
        }
    }

    ($fres, $ct);
}
my %str_levels = qw(1 critical 2 error 3 warning 4 info 5 debug 6 trace);

sub call {
    $log->tracef("=> PeriAHS::Respond middleware");

    my ($self, $env) = @_;

    die "This middleware needs psgi.streaming support"
        unless $env->{'psgi.streaming'};

    my $rreq = $env->{"riap.request"};
    my $pa   = $env->{"periahs.riap_client"}
        or die "\$env->{'periahs.riap_client'} not defined, ".
            "perhaps ParseRequest middleware has not run?";

    return sub {
        my $respond = shift;

        my $writer;
        my $loglvl  = $rreq->{'loglevel'} // 0;
        my $marklog = $rreq->{'marklog'};
        my $rres; #  short for riap response
        $env->{'periahs.start_action_time'} = [gettimeofday];
        if ($loglvl > 0) {
            $writer = $respond->([200, ["Content-Type" => "text/plain"]]);
            Log::Any::Adapter->set(
                {lexically=>\my $lex},
                "Callback",
                min_level => $str_levels{$loglvl} // 'warning',
                logging_cb => sub {
                    my ($method, $self, $format, @params) = @_;
                    my $msg0 = join(
                        "",
                        "[$method][", scalar(localtime), "] $format\n",
                    );
                    my $msg = join(
                        "",
                        $marklog ? "l" . length($msg0) . " " : "",
                        $msg0);
                    $writer->write($msg);
                },
            );
            $rres = $pa->request($rreq->{action} => $rreq->{uri}, $rreq);
        } else {
            $rres = $pa->request($rreq->{action} => $rreq->{uri}, $rreq);
        }
        $env->{'periahs.finish_action_time'} = [gettimeofday];

        $env->{'riap.response'} = $rres;
        my ($fres, $ct) = $self->format_result($rres, $env);

        if ($writer) {
            $writer->write($marklog ?
                               "r" . length($fres) . " " . $fres : $fres);
            $writer->close;
        } else {
            $respond->([200, ["Content-Type" => $ct], [$fres]]);
        }
    };
}

1;
# ABSTRACT: Send Riap request to Riap server and send the response to client

=for Pod::Coverage .*

=head1 SYNOPSIS

 # in your app.psgi
 use Plack::Builder;

 builder {
     enable "PeriAHS::Respond";
 };


=head1 DESCRIPTION

This middleware sends Riap request (C<$env->{"riap.request"}>) to Riap client
(L<Perinci::Access> object, stored in C<$env->{"periahs.riap_client"}> by
PeriAHS::ParseRequest middleware, thus this middleware requires the
PeriAHS::ParseRequest middleware), format the result, and send it to client.
This middleware is the one that sends response to client and should be put as
the last middleware after all the parsing, authentication, and authorization
middlewares.

The result will also be put in C<$env->{"riap.response"}>.

=head2 How loglevel and marklog works

If marklog is turned on by Riap request (which is required if client wants to
receive log messages interspersed with actual Riap response), the server will
encode each part with:

Log message:

 "l" + <number-of-bytes> + " " + <log message>
   example: l56 [trace][Thu Apr  4 06:41:09 2013] this is a log message!

Part of Riap response:

 "r" + <number-of-bytes> + " " + <data>
  example: r9 [200,"OK"]

So the actual HTTP response body might be something like this (can be sent by
the server in HTTP chunks, so that complete log messages can be displayed before
the whole Riap response is received):

 l56 [trace][Thu Apr  4 06:41:09 2013] this is a log message!
 l58 [trace][Thu Apr  4 06:41:09 2013] this is another log msg!
 r9 [200,"OK"]

Developer note: additional parameter in the future can be in the form of e.g.:

 "l" + <number-of-bytes> + ("," + <additional-param> )* + " "


=head1 CONFIGURATIONS

=over

=item * add_text_tips => BOOL (default: 1)

If set to 1, then when output format is C<text> or C<text-pretty>, additional
text tips can be added at the end of response. This helps autodiscoverability:
user can just start using something like:

 % curl http://host/api/
 ...

 Tips:
 * To call a function, try:
     http://host/api/func1
 * Function arguments can be given via GET/POST parameters or JSON request body
 * To find out which arguments a function supports, try:
     http://host/api/func1?-riap-action=meta
 * To list subpackages, try:
     http://host/api/SubModule/
 * To find out all available actions on an entity, try:
     http://host/api/SubModule?-riap-action=actions
 * This server uses Riap protocol for great autodiscoverability, for more info:
     https://metacpan.org/module/Riap

=back

=cut
